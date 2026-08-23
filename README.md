# Ignition Files

Provisioning configs for FCOS (Fedora CoreOS) machines using [Butane](https://coreos.github.io/butane/) → [Ignition](https://coreos.github.io/ignition/).

## Quick Start

```bash
# Transpile a .bu file into an .ign file
./butane.sh --strict nevua-ketana.bu nevua-ketana.ign

# With local file references (e.g. large config files)
./butane.sh --strict machine.bu machine.ign
# Local files are resolved relative to the working directory.

# Pass any butane args before the input/output files
./butane.sh --pretty --strict nevua-ketana.bu nevua-ketana.ign
```

## Boot Sequence

Ignition runs **once** at first boot. It handles all `storage:` operations (disk wiping, creating directories, writing files) before any systemd unit starts. After that, systemd takes over.

The provisioning here is designed as a **4-boot chain** — each step reboots and triggers the next:

| Boot | Unit | What it does |
|------|------|-------------|
| 1 | `ucore-unsigned-autorebase.service` | Rebases to unsigned OCI image, sets marker, reboots |
| 2 | `ucore-signed-autorebase.service` | Rebases to signed OCI image, sets marker, reboots |
| 3 | `install-user-packages.service` | Installs packages via `rpm-ostree`, sets marker, reboots |
| 4 | `setup-bcache.service` | Sets up bcache, formats, adds fstab entry (no reboot) |
| N | `wol-enable.service` | Runs at **every** boot — enables Wake-on-LAN |

### Why this ordering matters

The chain uses marker files (`/etc/ucore-autorebase/unverified`, `/etc/ucore-autorebase/signed`, `/var/lib/install-user-packages.done`) as conditions. Each unit checks for the previous marker before running, preventing race conditions.

**Critical:** `install-user-packages.service` depends on `ConditionPathExists=/etc/ucore-autorebase/signed`. Without this, it could race with the signed rebase on boot 2 — both units would try to `rpm-ostree` and reboot simultaneously.

Once a unit has run, it disables itself (`systemctl disable ...`), so it never fires again. The only exception is `wol-enable.service`, which runs every boot by design.

## File Structure

```
ignition-files/
├── butane.sh              # Transpilation wrapper
├── README.md              # This file
└── nevua-ketana.bu        # Per-machine butane config
```

Each `.bu` file is self-contained. Within each file, sections are tagged as **generic** or **machine-specific** via comments:

- **Generic** — shared across all machines (ucore autorebase, package installs, user setup). Copy these into new machine files.
- **Machine-specific** — unique to one machine (disk device IDs, bcache, hostname, WoL interface). These change per box.

### Why not split into multiple files?

Butane has no `include` or inheritance mechanism. Any composability requires custom merge tooling, which adds complexity for 1–3 machines. The plan is to stay single-file per machine until a second or third box makes copy-paste painful — at which point a `yq`-based merge script is the right step up.

## Adding a New Machine

1. Copy an existing `.bu` file as a starting point
2. Change `passwd.users[0].password_hash` and `ssh_authorized_keys`
3. Update machine-specific sections:
   - `storage.devices` — disk device paths
   - `storage.files` — hostname, WoL script interface
   - `systemd.units` — bcache devices, WoL service
4. Remove any units that don't apply (e.g. no bcache? remove `setup-bcache.service`)
5. Transpile: `./butane.sh --strict new-machine.bu new-machine.ign`

## Butane/Ignition Basics

- **Butane** (`.bu`) — human-friendly YAML. Transpiled into Ignition JSON.
- **Ignition** (`.ign`) — machine-readable JSON. Consumed by FCOS at first boot.
- Ignition is **not** a configuration management tool. It only runs once, at provisioning. After that the OS is immutable (ostree-based). Use `rpm-ostree`, `systemd`, or a proper config management tool for ongoing changes.
- `local:` file references in butane are resolved at **transpilation time** (the file is embedded as base64 into the `.ign`). They are not fetched at boot.
- `source:` (remote) references are fetched at **boot time** over HTTP/HTTPS.
