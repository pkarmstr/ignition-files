# Ignition Files

Provisioning configs for FCOS (Fedora CoreOS) machines using [Butane](https://coreos.github.io/butane/) → [Ignition](https://coreos.github.io/ignition/).

## Quick Start

```bash
# Transpile a .bu file into an .ign file
# ('--strict' is added automatically by butane.sh)
./butane.sh nevua-ketana.bu nevua-ketana.ign

# 'local:' file references (embedded scripts, config files) are resolved
# relative to the *input .bu file's directory*. butane.sh passes --files-dir
# to the container automatically — don't pass it yourself.

# Pass any butane args before the input/output files
./butane.sh --pretty nevua-ketana.bu nevua-ketana.ign

# The butane image is pinned for reproducibility (default:
# quay.io/coreos/butane:v0.29.0). Override with the BUTANE_IMAGE env var:
BUTANE_IMAGE=quay.io/coreos/butane:v0.30.0 ./butane.sh nevua-ketana.bu nevua-ketana.ign
```

## Installing onto a machine

Two HTTP servers have to run on this machine (erevrav, `192.168.0.24`). Both are
started by hand, and each has to be up when the step that needs it runs:

| Served directory | Port | Fetched by | When it must be running |
|---|---|---|---|
| this repo directory | 33333 | `coreos-installer --ignition-url` (the `.ign`) | during the install |
| `/mnt/storage/nevua-ketana-backup/20tb-hdd/llama-models` | 33334 | `fetch-models.service` (boot 4) | from the first boot of the installed system |

```bash
./butane.sh nevua-ketana.bu nevua-ketana.ign   # regenerate the .ign first
./serve.sh                                     # both servers, one foreground process
```

`serve.sh` runs the two `python3 -m http.server` commands and stops both on
Ctrl+C, so it lives happily in a tmux pane for the whole install. The two served
directories are the two variables at the top of it — the model directory it
serves is the layout under `/var/mnt/storage/llama-models`, so one path is both
the URL and the destination.

Then boot the machine into the Fedora CoreOS live image and:

```bash
lsblk                      # find the drive name of the ~500 GB NVMe (nvme0n1 today)
sudo coreos-installer install /dev/nvme0n1 \
  --ignition-url http://192.168.0.24:33333/nevua-ketana.ign \
  --insecure-ignition
sudo reboot
```

`--insecure-ignition` is required because the config comes over plain HTTP.
Everything after the install is automatic — see the boot sequence below. If the
second server was not up when boot 4 ran, `fetch-models.service` fails without
writing its marker; start the server and either reboot or run
`sudo systemctl start fetch-models.service` (as root — the script needs it).

## Boot Sequence

Ignition runs **once** at first boot. It handles all `storage:` operations (creating directories, writing files) before any systemd unit starts. After that, systemd takes over.

Ignition deliberately does **no** disk wiping here. `wipe_table` only clears the partition table and the signatures at the very start and end of a disk, and splitting the job across two systems makes the failure mode confusing. `setup-storage.sh` wipes both data disks with `wipefs --all` as its first step, so wiping and building live in one readable, testable file.

The provisioning here is designed as a **3-reboot chain** — each step reboots and triggers the next — followed by a one-shot storage setup and model fetch on the boot that follows. The end state of that boot is a running llama.cpp server: a minimum viable system.

| Boot | Unit | What it does |
|------|------|-------------|
| 1 | `ucore-unsigned-autorebase.service` | Rebases to unsigned OCI image, sets marker, reboots |
| 2 | `ucore-signed-autorebase.service` | Rebases to signed OCI image, sets marker, reboots |
| 3 | `install-user-packages.service` | Installs packages via `rpm-ostree`, sets marker, reboots |
| 4 | `setup-storage.service` | Runs `/usr/local/bin/setup-storage.sh` once: wipes both data disks, builds the LVM cache volume, formats XFS, sets marker, starts `var-mnt-storage.mount`, disables itself (no reboot) |
| 4..N | `var-mnt-storage.mount` | Mounts `vg_storage/lv_data` (XFS) on `/var/mnt/storage`. Skipped until the marker above exists; on boot 4 it is started by `setup-storage.service` itself |
| 4 (later) | `fetch-models.service` | Waits for that mount, fetches the model + chat template from erevrav into `/var/mnt/storage/llama-models`, sets its marker, starts `llama-server.service`, disables itself (no reboot) |
| 4..N | `llama-server.service` | The quadlet (`llama-server.container`), enabled at every boot but **gated** on `/var/lib/fetch-models.done` — skipped, never failed, until the model exists |
| N | `wol-enable.service` | Runs at **every** boot — enables Wake-on-LAN |

### Why this ordering matters

The chain uses marker files (`/etc/ucore-autorebase/unverified`, `/etc/ucore-autorebase/signed`, `/var/lib/install-user-packages.done`) as conditions. Each unit checks for the previous marker before running, preventing race conditions.

**Critical:** `install-user-packages.service` depends on `ConditionPathExists=/etc/ucore-autorebase/signed`. Without this, it could race with the signed rebase on boot 2 — both units would try to `rpm-ostree` and reboot simultaneously.

Once a unit has run, it disables itself (`systemctl disable ...` or a done marker), so it never fires again. The exception is the every-boot unit `wol-enable.service` (enables Wake-on-LAN).

### The storage mount

FCOS has no `/etc/fstab` (and mutating one at runtime is an anti-pattern on an immutable image), so the data volume is mounted by a native systemd unit, `var-mnt-storage.mount`, declared in the `.bu`. Points worth knowing:

- **The gate is `/var/lib/setup-storage.done`.** `ConditionPathExists=` on `setup-storage.service`'s done marker means the mount is simply skipped on the boots before the volume exists — conditions are checked when the job starts, so it skips in milliseconds instead of hanging on the ~90 s implicit wait for `/dev/vg_storage/lv_data`. Once the marker exists, waiting for LVM is the implicit `Requires=`/`After=` dependency on `dev-vg_storage-lv_data.device`'s job.
- **Same-boot mount.** Because the gate fails early in boot 4, the unit is not retried by itself, so `setup-storage.service` ends with `ExecStart=/usr/bin/systemctl --no-block start var-mnt-storage.mount`. `--no-block` is mandatory: a blocking `systemctl start` from inside a oneshot can deadlock the transaction.
- **`WantedBy=multi-user.target`, not `local-fs.target`,** together with `nofail` in `Options=`. `nofail` is swallowed by libmount (never reaches the kernel) but it drops systemd's automatic `Before=local-fs.target` ordering, so a missing or degraded volume can never stall the local-fs phase — `multi-user.target` only `Wants=` the mount, so a failed mount is a failed unit, not a hung boot. It also has to be `enabled` (with an `[Install]` section): systemd ≥ v257 no longer injects `local-fs.target Wants=<mount>`, so nothing pulls a mount unit in on its own.
- **`x-systemd.*` options are fstab-only** (`x-systemd.device-timeout=`, `x-systemd.mount-timeout=`, `x-systemd.makefs`). `systemd.mount(5)` states they are ignored when written in a unit's `Options=`, which is why they are not used.
- **`llama-server.container` depends on it** via `RequiresMountsFor=/var/mnt/storage`, so the container cannot start against an empty mount point (its `/models` bind source lives on the volume) and lose its `--models-preset`.
- **Nothing above the mount is ordered against a same-boot remount.** `setup-storage.service` re-queues the mount with `--no-block` at the end of its own job, and an `After=` edge cannot order against a job that does not exist yet — the mount job in that boot's transaction was already skipped by the gate. Anything that writes to the volume on that same boot checks `mountpoint(8)` itself (that is what the wait loop at the top of `fetch-models.sh` is for).
- **The volume root's owner *and* SELinux label are written once by `setup-storage.sh`**, not by the mount unit. Both are filesystem content (the XFS root inode), so writing them while the volume is empty and mounted is enough forever; `ls -ldZ /var/mnt/storage` shows them after any reboot. The label matters as much as the owner: `mkfs.xfs` stores no `security.selinux` xattr, so a freshly formatted root mounts as `unlabeled_t` instead of inheriting the mount point's `mnt_t`, and everything created under it inherits `unlabeled_t` too. From `keelan` that is invisible — `unconfined_t` is allowed `unlabeled_t` — but a confined domain (the container) is denied it, so the step `restorecon`s it. The mode stays `mkfs`' 0755: owner `rwx`, everyone else `r-x`.

### The model fetch

Ignition cannot carry a 30 GB model, and the whole model library is several TB,
so a fresh machine takes one model — the one in `FILES` in `fetch-models.sh` —
and the llama.cpp server starts against it. Notes on how that is wired:

- **Two servers, two ports.** The `.ign` server (33333) only has to outlive the
  install; the model server (33334) has to be up for boot 4. `python3 -m
  http.server` answers GET only and implements no `Range` header, so a broken
  transfer cannot be resumed: `curl --retry` restarts the file from byte 0, and
  so does re-running the script. That is why the size of every fetched file is
  hard-coded — the check that turns a truncated file into an error instead of a
  model that answers with garbage.
- **Marker + gate.** `/var/lib/fetch-models.done` is both the "run once" marker
  and the condition that lets `llama-server.service` run. A quadlet with an
  `[Install]` section is enabled by the generator on every boot, so the gate is
  a `ConditionPathExists=` in the quadlet's `[Unit]`: a condition skip is not a
  failure, so `Restart=always` never crash-loops on an empty volume. On the boot
  that fetches, the marker appears after that unit's job was already skipped, so
  `fetch-models.service` ends with `systemctl --no-block start llama-server.service`.
- **Layout.** `/var/mnt/storage/llama-models` is bind-mounted as `/models` — the
  models sit directly under `/models`, no extra `llama-models` layer in the
  container — and that directory mirrors the served directory (the old box's
  `llama-models`) one for one. So the paths in `llama-server-config.ini` (under
  `/models`), in `fetch-models.sh` (under `DEST_ROOT`) and on disk are the same
  paths. A later full restore is an `rsync` of that one directory — no renaming,
  no re-linking.

## File Structure

```
ignition-files/
├── butane.sh                     # Transpilation wrapper
├── serve.sh                      # Run by hand: the two HTTP servers an install needs from this machine
├── README.md                     # This file
├── AGENTS.md                     # Rules for AI agents working in this repo
├── HARDWARE.md                   # Hardware + stable drive identifiers (nevua-ketana)
├── nevua-ketana.bu               # Per-machine butane config
├── llama-server.container        # Machine-specific: podman quadlet (embedded via local:)
├── llama-server-config.ini       # Machine-specific: llama.cpp preset config (embedded via local:)
├── llama-server-firewall.service # Machine-specific: firewalld rule for port 8001 (embedded via local:)
├── fetch-models.sh               # Machine-specific: pulls the model files from erevrav onto the volume (embedded verbatim as /usr/local/bin/fetch-models.sh)
├── setup-storage.sh              # Machine-specific: wipes the 2 data disks, LVM cache setup (embedded verbatim as /usr/local/bin/setup-storage.sh)
└── teardown-storage.sh           # Machine-specific: destroys the volume again (run by hand, not embedded)
```

Each `.bu` file is self-contained. Within each file, sections are tagged as **generic** or **machine-specific** via comments:

- **Generic** — shared across all machines (ucore autorebase, package installs, user setup). Copy these into new machine files.
- **Machine-specific** — unique to one machine (hostname, WoL interface, services). These change per box.

### Why not split into multiple files?

Butane has no `include` or inheritance mechanism. Any composability requires custom merge tooling, which adds complexity for 1–3 machines. The plan is to stay single-file per machine until a second or third box makes copy-paste painful — at which point a `yq`-based merge script is the right step up.

## Adding a New Machine

1. Copy an existing `.bu` file as a starting point
2. Change `passwd.users[0].password_hash` and `ssh_authorized_keys`
3. Update machine-specific sections in the `.bu`:
   - `storage.files` — hostname, WoL script interface
   - `systemd.units` — WoL service, and the storage mount unit (`var-mnt-storage.mount`:
     unit name, `What=`, `Where=` all change per box)
4. Update the machine-specific helper files (embedded into the `.bu` via
   `local:` references), e.g. the llama-server quadlet, config, and firewall
   service, and `fetch-models.sh` (its `BASE_URL` port, `DEST_ROOT` and `FILES`).
5. Remove any units/files that don't apply to the new machine.
6. Transpile: `./butane.sh new-machine.bu new-machine.ign`

## Butane/Ignition Basics

- **Butane** (`.bu`) — human-friendly YAML. Transpiled into Ignition JSON.
- **Ignition** (`.ign`) — machine-readable JSON. Consumed by FCOS at first boot.
- Ignition is **not** a configuration management tool. It only runs once, at provisioning. After that the OS is immutable (ostree-based). Use `rpm-ostree`, `systemd`, or a proper config management tool for ongoing changes.
- `local:` file references in butane are resolved at **transpilation time** (the file is embedded as base64 into the `.ign`). They are not fetched at boot.
- `source:` (remote) references are fetched at **boot time** over HTTP/HTTPS.
- Storage keys are **snake_case** (`wipe_table`, `size_mib`, `wipe_filesystem`), not
 camelCase. A wrong spelling is only reported as an `unused key` warning and is
 silently dropped from the `.ign` — which is why `butane.sh` always passes `--strict`.
 (This is Butane's YAML schema only; file and unit names in this repo are kebab-case.)
