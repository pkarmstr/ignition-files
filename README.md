# Ignition Files

Provisioning configs for FCOS (Fedora CoreOS) machines using [Butane](https://coreos.github.io/butane/) → [Ignition](https://coreos.github.io/ignition/).

> **Storage layout (nevua-ketana).** `/var/mnt/cached-storage` is an XFS
> filesystem on a bcache device: 20TB HDD as backing, 1TB NVMe as writearound
> read cache. At first provisioning, Ignition wipes the partition tables of
> both member disks (`storage.disks`, `wipe_table: true`) so the one-time
> bcache init starts from a clean slate. The lifecycle is otherwise fully
> stateful-systemd (no `/etc/fstab`):
>
> - `/usr/local/bin/bcache-setup.sh` (via `bcache-setup.sh`, embedded) —
>   state-aware engine: every boot it *assembles* the existing bcache set
>   non-destructively; it only falls back to a destructive first-time init
>   (`wipefs` + `make-bcache` + `mkfs.xfs`) if assembly fails **and**
>   `/var/lib/bcache-setup.done` is absent.
> - `bcache-assemble.service` — runs every boot (never disables itself),
>   strictly after `install-user-packages.service` (layers `bcache-tools`)
>   and before `local-fs.target` (the mount phase).
> - `var-mnt-cached\x2dstorage.mount` — native mount unit (escaped name for
>   `/var/mnt/cached-storage`), with `nofail,x-systemd.device-timeout=1ms`
>   so boot never blocks on the device, and `Before=llama-server.service`.
> - The llama-server quadlet `Requires=` the mount unit, so the container
>   cannot start before the model volume is up.

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

## Boot Sequence

Ignition runs **once** at first boot. It handles all `storage:` operations (disk wiping, creating directories, writing files) before any systemd unit starts. After that, systemd takes over.

The provisioning here is designed as a **3-boot chain** — each step reboots and triggers the next:

| Boot | Unit | What it does |
|------|------|-------------|
| 1 | `ucore-unsigned-autorebase.service` | Rebases to unsigned OCI image, sets marker, reboots |
| 2 | `ucore-signed-autorebase.service` | Rebases to signed OCI image, sets marker, reboots |
| 3 | `install-user-packages.service` | Installs packages (incl. `bcache-tools`) via `rpm-ostree`, sets marker, reboots |
| N | `bcache-assemble.service` | Runs at **every** boot — assembles the bcache set (first boot *after* boot 3 does the one-time format) |
| N | `var-mnt-cached\x2dstorage.mount` | Runs at **every** boot — mounts the bcache XFS volume (`nofail`; never blocks boot) |
| N | `wol-enable.service` | Runs at **every** boot — enables Wake-on-LAN |

### Why this ordering matters

The chain uses marker files (`/etc/ucore-autorebase/unverified`, `/etc/ucore-autorebase/signed`, `/var/lib/install-user-packages.done`) as conditions. Each unit checks for the previous marker before running, preventing race conditions.

**Critical:** `install-user-packages.service` depends on `ConditionPathExists=/etc/ucore-autorebase/signed`. Without this, it could race with the signed rebase on boot 2 — both units would try to `rpm-ostree` and reboot simultaneously.

Once a unit has run, it disables itself (`systemctl disable ...` or a done marker), so it never fires again. The exceptions are the every-boot units: `bcache-assemble.service` (reassembles bcache), `var-mnt-cached\x2dstorage.mount` (mounts the volume), and `wol-enable.service` (enables Wake-on-LAN).

## File Structure

```
ignition-files/
├── butane.sh                     # Transpilation wrapper
├── README.md                     # This file
├── nevua-ketana.bu               # Per-machine butane config
├── bcache-setup.sh               # Machine-specific: state-aware bcache engine (embedded via local:)
├── llama-server.container        # Machine-specific: podman quadlet (embedded via local:)
├── llama-server-config.ini       # Machine-specific: llama.cpp preset config (embedded via local:)
└── llama-server-firewall.service # Machine-specific: firewalld rule for port 8001 (embedded via local:)
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
   - `systemd.units` — WoL service
4. Update the machine-specific helper files (embedded into the `.bu` via
   `local:` references), e.g. the llama-server quadlet, config, and firewall service.
5. Remove any units/files that don't apply to the new machine.
6. Transpile: `./butane.sh new-machine.bu new-machine.ign`

## Butane/Ignition Basics

- **Butane** (`.bu`) — human-friendly YAML. Transpiled into Ignition JSON.
- **Ignition** (`.ign`) — machine-readable JSON. Consumed by FCOS at first boot.
- Ignition is **not** a configuration management tool. It only runs once, at provisioning. After that the OS is immutable (ostree-based). Use `rpm-ostree`, `systemd`, or a proper config management tool for ongoing changes.
- `local:` file references in butane are resolved at **transpilation time** (the file is embedded as base64 into the `.ign`). They are not fetched at boot.
- `source:` (remote) references are fetched at **boot time** over HTTP/HTTPS.
