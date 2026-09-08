# Ignition Files

Provisioning configs for FCOS (Fedora CoreOS) machines using [Butane](https://coreos.github.io/butane/) → [Ignition](https://coreos.github.io/ignition/).

## Quick Start

```bash
# Transpile a machine's config.bu into builds/<machine>.ign
# ('--strict' is added automatically by butane.sh)
./butane.sh nevua-ketana

# Secrets (the password hash and SSH public key) are NOT in the .bu. They live
# in a gitignored 'secrets.env' next to the .bu and are substituted into a
# temp copy by butane.sh at transpile time:
#   USER_PASSWORD_HASH='...'
#   USER_SSH_PUBLIC_KEY='ssh-rsa ...'

# 'local:' file references (embedded scripts, config files) are resolved
# relative to the machine directory. butane.sh passes --files-dir to the
# container automatically — don't pass it yourself.

# Pass any butane args before the machine directory
./butane.sh --pretty nevua-ketana

# The butane image is pinned for reproducibility (default:
# quay.io/coreos/butane:v0.29.0). Override with the BUTANE_IMAGE env var:
BUTANE_IMAGE=quay.io/coreos/butane:v0.30.0 ./butane.sh nevua-ketana
```

## Installing onto a machine

The generated `.ign` is served over plain HTTP from this machine (erevrav,
`192.168.0.24`), started by hand and kept up while the step that needs it runs:

| Served directory | Port | Fetched by | When it must be running |
|---|---|---|---|
| `builds/` (the generated `.ign` files) | 33333 | `coreos-installer --ignition-url` | during the install — either machine |
| `/mnt/storage/nevua-ketana-backup/20tb-hdd/llama-models` | 33334 | `fetch-models.service` (boot 4) | from the first boot of a nevua-ketana install |

```bash
./butane.sh nevua-ketana      # regenerate the .ign first
./nevua-ketana/serve.sh       # both servers, one foreground process (nevua-ketana installs)
```

`serve.sh` runs the two `python3 -m http.server` commands and stops both on
Ctrl+C, so it lives happily in a tmux pane for the whole install. The two served
directories are the two variables at the top of it — the model directory it
serves is the layout under `/var/mnt/storage/llama-models`, so one path is both
the URL and the destination. A hava-amina install needs only the first server:
`python3 -m http.server 33333 -d builds` in a tmux pane is enough.

Then boot the machine into the Fedora CoreOS live image and install onto the
drive the machine's `HARDWARE.md` names as its OS drive. Use the by-id path,
not the `nvmeNn1` name — the number can swap between boots, and on hava-amina
the two drives are physically identical, so a wrong guess is destructive (its
`.ign` wipes the storage drive on first boot):

| Machine | Install target |
|---|---|
| nevua-ketana | `/dev/disk/by-id/nvme-PCIe_SSD_20090851200275` (the 512 GB NVMe) |
| hava-amina | `/dev/disk/by-id/nvme-PCIe_SSD_511250820055001423` (M.2 slot 1; the `...1080` drive is its storage disk) |

```bash
sudo coreos-installer install <os drive by-id path> \
  --ignition-url http://192.168.0.24:33333/<machine>.ign \
  --insecure-ignition
sudo reboot
```

`--insecure-ignition` is required because the config comes over plain HTTP.
Everything after the install is automatic — see the boot sequence below.
(nevua-ketana only) If the second server was not up when boot 4 ran,
`fetch-models.service` fails without writing its marker; start the server and
either reboot or run `sudo systemctl start fetch-models.service` (as root — the
script needs it).

## Boot Sequence (nevua-ketana)

Ignition runs **once** at first boot. It handles all `storage:` operations (creating directories, writing files) before any systemd unit starts. After that, systemd takes over.

Ignition deliberately does **no** disk wiping here. `wipe_table` only clears the partition table and the signatures at the very start and end of a disk, and splitting the job across two systems makes the failure mode confusing. `setup-storage.sh` wipes both data disks with `wipefs --all` as its first step, so wiping and building live in one readable, testable file.

The provisioning here is a **3-reboot rebase chain** — each step reboots and triggers the next — and on nevua-ketana a one-shot storage setup and model fetch follow it on the boot after. The end state of that boot is a running llama.cpp server: a minimum viable system.

| Boot | Unit | What it does |
|------|------|-------------|
| 1 | `ucore-unsigned-autorebase.service` | Rebases to unsigned OCI image, sets marker, reboots |
| 2 | `ucore-signed-autorebase.service` | Rebases to signed OCI image, sets marker, reboots |
| 3 | `install-user-packages.service` | Installs packages via `rpm-ostree`, sets marker, reboots |
| 4 | `setup-storage.service` | Runs `/usr/local/bin/setup-storage.sh` once: wipes both data disks, builds the LVM cache volume, formats XFS, sets marker, starts `var-mnt-storage.mount`, disables itself (no reboot) |
| 4..N | `var-mnt-storage.mount` | Mounts `vg_storage/lv_data` (XFS) on `/var/mnt/storage`. Skipped until the marker above exists; on boot 4 it is started by `setup-storage.service` itself |
| 4 (later) | `fetch-models.service` | Waits for that mount, fetches the model, chat template and preset INI from erevrav into `/var/mnt/storage/llama-models`, sets its marker, starts `llama-server.service`, disables itself (no reboot) |
| 4..N | `llama-server.service` | The quadlet (`llama-server.container`), enabled at every boot but **gated** on `/var/lib/fetch-models.done` — skipped, never failed, until the model exists. Pulls the `server-cuda13` tag on every start (0.6 s unchanged, 3.32 GB changed) |
| N | `wol-enable.service` | Runs at **every** boot — enables Wake-on-LAN |

`hava-amina` follows the same rebase chain (boots 1–3) but has no boot-4
storage step: its storage disk is wiped and formatted by Ignition itself on
the first boot (`storage.disks` / `storage.filesystems` in the `.bu`), before
any systemd unit runs. The only storage unit on that machine is the one-shot
`storage-owner.service`, which sets the volume root's owner and SELinux label
once (see the unit's comment in its `config.bu`).

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
- **hava-amina's `var-mnt-storage.mount`** follows the same nofail / multi-user
  rules but has **no condition gate**: its disk is a plain whole-disk XFS volume
  formatted by Ignition on the first boot, so the device exists whenever the
  mount is attempted. It is written by hand rather than generated with
  `with_mount_unit` for the same nofail reason (the unit butane generates is
  `RequiredBy=local-fs.target` without nofail).
- **Nothing above the mount is ordered against a same-boot remount.** `setup-storage.service` re-queues the mount with `--no-block` at the end of its own job, and an `After=` edge cannot order against a job that does not exist yet — the mount job in that boot's transaction was already skipped by the gate. Anything that writes to the volume on that same boot checks `mountpoint(8)` itself (that is what the wait loop at the top of `fetch-models.sh` is for).
- **The volume root's owner *and* SELinux label are written once by `setup-storage.sh`**, not by the mount unit. Both are filesystem content (the XFS root inode), so writing them while the volume is empty and mounted is enough forever; `ls -ldZ /var/mnt/storage` shows them after any reboot. The label matters as much as the owner: `mkfs.xfs` stores no `security.selinux` xattr, so a freshly formatted root mounts as `unlabeled_t` instead of inheriting the mount point's `mnt_t`, and everything created under it inherits `unlabeled_t` too. From `keelan` that is invisible — `unconfined_t` is allowed `unlabeled_t` — but a confined domain (the container) is denied it, so the step `restorecon`s it. The mode stays `mkfs`' 0755: owner `rwx`, everyone else `r-x`.

### The model fetch

Ignition cannot carry a 30 GB model, and the whole model library is several TB,
so a fresh machine takes the files listed in `FILES` in `fetch-models.sh` — one
model, its chat template, and the router's preset INI — and the llama.cpp server
starts against them. Notes on how that is wired:

- **Two servers, two ports.** The `.ign` server (33333) only has to outlive the
  install; the model server (33334) has to be up for boot 4. `python3 -m
  http.server` answers GET only and implements no `Range` header, so a broken
  transfer cannot be resumed: `curl --retry` restarts the file from byte 0, and
  so does re-running the script. Every file is fetched unconditionally over
  whatever is at the destination — this runs once, onto a volume that was just
  formatted — so a re-run after a failure is a plain re-fetch, with no sizes or
  checksums to keep in step with the served files.
- **Marker + gate.** `/var/lib/fetch-models.done` is both the "run once" marker
  and the condition that lets `llama-server.service` run. A quadlet with an
  `[Install]` section is enabled by the generator on every boot, so the gate is
  a `ConditionPathExists=` in the quadlet's `[Unit]`: a condition skip is not a
  failure, so `Restart=always` never crash-loops on an empty volume. On the boot
  that fetches, the marker appears after that unit's job was already skipped, so
  `fetch-models.service` ends with `systemctl --no-block start llama-server.service`.
- **Layout.** `/var/mnt/storage/llama-models` is bind-mounted as `/models` — the
  models sit directly under `/models`, no extra `llama-models` layer in the
  container, and so does `llama-server-config.ini`, which is the file the server
  reads as its `--models-preset` — and that directory mirrors the served
  directory (the old box's `llama-models`) one for one. So the paths in
  `llama-server-config.ini` (under `/models`), in `fetch-models.sh` (under
  `DEST_ROOT`) and on disk are the same paths. A later full restore is an `rsync`
  of that one directory — no renaming, no re-linking, config included.

## The llama.cpp server

One container is the whole server: the rootful quadlet
`/etc/containers/systemd/llama-server.container`, writing the unit
`llama-server.service`, with exactly one bind: the model tree
`/var/mnt/storage/llama-models` → `/models`, which also carries the preset INI.

### Router mode

`--models-preset /models/llama-server-config.ini` runs llama.cpp in **router
mode**: each INI section is a model ID, and the router spawns a child
`llama-server` instance for the one a client asks for, then loads and unloads
them on demand.

| Endpoint | Meaning |
|---|---|
| `GET /v1/models` | the model IDs and each one's `status.value` (`loaded` / `loading` / `unloaded`) |
| `POST /models/load` `{"model":"<id>"}` | load one now |
| `POST /models/unload` `{"model":"<id>"}` | free it again |
| `GET /props` | router settings — `max_instances`, `models_autoload`, `build_info` |
| `GET /health` | router **liveness**, not model readiness: `200` even with nothing loaded |

- **`--models-max 1`** — one instance at a time. The default is 4, and four copies of a 29 GB model on 2×24 GB GPUs is an OOM, not a feature.
- **A loaded model stays loaded.** There is deliberately no `--sleep-idle-seconds`: nothing unloads on a timer, so a model holds its memory until you `POST /models/unload` it or the container restarts. The consequence of pairing that with `--models-max 1` is that the single slot is always occupied — to serve a second model, unload the first one.
- **Nothing is preloaded.** The log says `starting server in router mode. models will be automatically loaded on-demand`, and a model appears only when a client asks for it (or you `POST /models/load`). `unloaded` in `/v1/models` on a freshly started server is normal, not broken.
- **The health check is liveness only** — `curl -fsS http://127.0.0.1:8001/health` every 30 s, 60 s start period, and deliberately **no** `HealthOnFailure`: an HTTP check must not be able to kill a session. `curl` is in the image, `wget` is not.

### Changing the model config

`llama-server-config.ini` is part of the model tree, not of the OS. Nothing in
`/etc` points at it, and the box's copy is owned by `keelan`, so editing it needs
no sudo. Three copies exist and each has a job:

| Copy | Role |
|---|---|
| the served directory on erevrav | what a fresh install fetches — an entry in `FILES`, byte-size checked like every other file |
| this repo | the copy git keeps, so a preset change is reviewable |
| `/var/mnt/storage/llama-models/` on the box | what the server actually reads |

An edit therefore has three destinations and one restart:

```bash
vi llama-server-config.ini                                                      # git records it
scp llama-server-config.ini keelan@192.168.0.45:/var/mnt/storage/llama-models/  # the live box (no sudo)
cp llama-server-config.ini /mnt/storage/nevua-ketana-backup/20tb-hdd/llama-models/  # future installs
ssh keelan@192.168.0.45 'sudo systemctl restart llama-server.service'           # apply
```

A config change needs a **restart only**: no `daemon-reload` (that is for quadlet
edits, where the generator has to re-run) and no `.ign` rebuild (that only
matters on a reinstall). The router reads the presets once per process start —
watch for `Loaded N custom model presets from /models/llama-server-config.ini` —
and the restart recreates the container, so the resident model goes with it and
returns on the next request. `fetch-models.sh` is not a sync mechanism: it runs
once per provisioning and its marker keeps it that way.

(The served directory also still holds `config.ini`, the *old* machine's preset
file with `/mnt/20tb-hdd/...` paths. It is fetched by nothing and read by nobody;
reconciling the two files is open work.)

### Pull on boot

`Pull=always` puts the pull inside the start path (`podman run --pull always`), so every start re-resolves `server-cuda13` and a boot runs the newest llama.cpp build — no update mechanism to maintain, and no update timer either: no `AutoUpdate=`, no `podman-auto-update.timer`, no `.image` units.

- Unchanged tag: one manifest check, ~0.6 s. Changed tag: 3.32 GB **inside the start job**, which is why the unit sets `TimeoutStartSec=infinity` — the 90 s default would kill a healthy download mid-layer.
- No registry or no DNS at boot makes podman fail in under a second. `StartLimitIntervalSec=0` plus `RestartSec=15s` means it then retries **forever** instead of tripping the default rate limit (5 starts per 10 s) and staying in `failed`: measured against a nonexistent tag, failures at 05:29:24, :39, :55, 05:30:10 with `NRestarts` climbing and the unit held in `activating`. The box comes back on its own when the network does.
- Which situation you are in: `systemctl status llama-server.service` (`activating (auto-restart)` = retrying) and `journalctl -u llama-server.service -b`. A pull failure logs `Error: unable to copy from source docker://…` and a podman `image pull-error` event line.
- `systemctl show -p TimeoutStartSec` prints **nothing** on systemd 259 — the properties are `TimeoutStartUSec` and `StartLimitIntervalUSec`. A missing line means a wrong property name, not a missing setting; the truth is in the generated `/run/systemd/generator/llama-server.service`.

### Image garbage

A pull that actually changes the tag leaves the previous image behind, untagged:

```bash
sudo podman images -a --no-trunc   # full IDs, including the <none> rows
sudo podman image prune -f         # dangling only — never removes tagged or in-use images
```

There is deliberately **no prune timer**: pruning is what destroys the rollback
below, so it stays a human decision.

### Manual rollback

```bash
# BEFORE the first pull that changes anything, record the known-good image:
sudo podman image inspect --format '{{.Id}}' ghcr.io/ggml-org/llama.cpp:server-cuda13

# A new build is broken at runtime (starts, cannot load / serve):
sudo podman images -a --no-trunc | grep llama           # find the previous image ID
sudo podman tag <old-image-id> ghcr.io/ggml-org/llama.cpp:server-cuda13
sudo systemctl restart llama-server.service            # --replace picks up the re-tagged image
```

`Pull=always` re-resolves the tag on the *next* start, so a re-tag only survives
until the next boot or restart — that is honest: pinning is a repo edit (point
`Image=` at a digest or a dated tag), not a runtime accident.

### Changing the quadlet on an installed box

An `.ign` change only takes effect on a **reinstall** — Ignition runs once. A live
box is brought to the repo's version of the quadlet by replacing the embedded
file and reloading:

```bash
# One bad key makes the generator skip the WHOLE file: no unit, and only a
# journal line ("unsupported key … in group 'Container'") as evidence. So check
# the syntax where nothing can run, first:
scp llama-server.container keelan@192.168.0.45:/tmp/
ssh keelan@192.168.0.45 'sudo cp /tmp/llama-server.container /run/containers/systemd/qsyntax-check.container &&
  sudo /usr/lib/systemd/system-generators/podman-system-generator --dryrun |
    sed -n "/---qsyntax-check/,/^---/p";
  sudo rm -f /run/containers/systemd/qsyntax-check.container'
# expect a full unit (--pull always, --health-cmd, TimeoutStartSec=infinity) and
# no "unsupported key" line — an empty section means the file produced nothing

ssh keelan@192.168.0.45 'sudo cp /tmp/llama-server.container /etc/containers/systemd/llama-server.container &&
  sudo systemctl daemon-reload && sudo systemctl restart llama-server.service'
```

`daemon-reload` re-runs the quadlet generator; `restart` recreates the container
(`podman run --replace`), so whatever was loaded goes with it — expect a pull
plus ~40 s before the next request is answered.

## File Structure

```
ignition-files/
├── butane.sh                     # Transpilation wrapper: ./butane.sh <machine-dir>
├── builds/ (gitignored)          # Generated .ign files, one per machine
├── README.md                     # This file
├── AGENTS.md                     # Rules for AI agents working in this repo
├── nevua-ketana/                 # One folder per machine: config.bu + its helper files + HARDWARE.md
│   ├── config.bu                 # Per-machine butane config
│   ├── secrets.env (gitignored)  # Password hash + SSH public key, substituted into the .bu by butane.sh
│   ├── HARDWARE.md               # Hardware + stable drive identifiers
│   ├── serve.sh                  # Run by hand: the two HTTP servers an install needs from this machine
│   ├── llama-server.container    # Machine-specific: podman quadlet — pull-on-boot llama.cpp router (embedded via local:)
│   ├── llama-server-firewall.service # Machine-specific: firewalld rule for port 8001 (embedded via local:)
│   ├── fetch-models.sh           # Machine-specific: pulls the model files from erevrav onto the volume (embedded verbatim as /usr/local/bin/fetch-models.sh)
│   ├── setup-storage.sh          # Machine-specific: wipes the 2 data disks, LVM cache setup (embedded verbatim as /usr/local/bin/setup-storage.sh)
│   └── teardown-storage.sh       # Machine-specific: destroys the volume again (run by hand, not embedded)
└── hava-amina/                   # AMD box, no NVIDIA: ucore-minimal + whole-disk XFS storage, no llama units
    ├── config.bu                 # Per-machine butane config (storage is declarative: storage.disks/filesystems + custom mount unit + one-shot ownership unit)
    ├── secrets.env (gitignored)  # Same as above
    └── HARDWARE.md               # Hardware + stable drive identifiers
```

Each `.bu` file is self-contained. Within each file, sections are tagged as **generic** or **machine-specific** via comments:

- **Generic** — shared across all machines (ucore autorebase, package installs, user setup). Copy these into new machine files.
- **Machine-specific** — unique to one machine (hostname, WoL interface, services). These change per box.

### Why not split into multiple files?

Butane has no `include` or inheritance mechanism. Any composability requires custom merge tooling, which adds complexity for 1–3 machines. The plan is to stay single-file per machine until a second or third box makes copy-paste painful — at which point a `yq`-based merge script is the right step up.

## Adding a New Machine

1. Make a `<name>/` folder and copy an existing machine's `config.bu` (and the
   helper files it embeds) in as a starting point
2. Create a `secrets.env` next to the new `.bu` with the machine's
   `USER_PASSWORD_HASH` and `USER_SSH_PUBLIC_KEY` (the `.bu` carries
   `${...}` placeholders; butane.sh substitutes them at transpile time)
3. Update machine-specific sections in the `.bu`:
   - `storage.files` — hostname, WoL script interface
   - `systemd.units` — WoL service, and the storage mount unit (`var-mnt-storage.mount`:
     unit name, `What=`, `Where=` all change per box)
4. Update the machine-specific helper files (embedded into the `.bu` via
   `local:` references), e.g. the llama-server quadlet and the firewall service,
   and `fetch-models.sh` (its `BASE_URL` port, `DEST_ROOT` and `FILES`). Models
   and the preset INI are *not* embedded — they arrive over the model server, so
   a new box's model set is a `FILES` edit plus a `llama-server-config.ini`
   edit, never an Ignition edit.
5. Remove any units/files that don't apply to the new machine.
6. Transpile: `./butane.sh new-machine` (writes `builds/new-machine.ign`)

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
