# Ignition Files

Provisioning configs for FCOS (Fedora CoreOS) machines using [Butane](https://coreos.github.io/butane/) → [Ignition](https://coreos.github.io/ignition/).

> **⚠️ Data-loss warning — first bcache setup wipes two disks.** The first run
> of `setup-bcache.sh` (boot 4 of the chain) wipes and reformats **both** the
> 1 TB NVMe cache disk (`nvme0n1`) and the 20 TB backing HDD (`sda`). Any
> existing data on those disks is destroyed. Back up anything on the backing
> disk elsewhere **before** provisioning. After setup, restore the llama.cpp
> models to `/var/mnt/cached-storage/llama-models` — the quadlet mounts exactly
> that path as the container's `/models`.

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

The provisioning here is designed as a **4-boot chain** — each step reboots and triggers the next:

| Boot | Unit | What it does |
|------|------|-------------|
| 1 | `ucore-unsigned-autorebase.service` | Rebases to unsigned OCI image, sets marker, reboots |
| 2 | `ucore-signed-autorebase.service` | Rebases to signed OCI image, sets marker, reboots |
| 3 | `install-user-packages.service` | Installs packages via `rpm-ostree`, sets marker, reboots |
| 4 | `setup-bcache.service` | **Wipes both bcache disks**, sets up bcache, formats, adds fstab entry (no reboot) |
| N | `bcache-reassemble.service` | Runs at **every** boot, before local filesystems — reassembles the bcache set (the kernel does not auto-assemble), so the `/var/mnt/cached-storage` mount works after reboots |
| N | `wol-enable.service` | Runs at **every** boot — enables Wake-on-LAN |

### Why this ordering matters

The chain uses marker files (`/etc/ucore-autorebase/unverified`, `/etc/ucore-autorebase/signed`, `/var/lib/install-user-packages.done`) as conditions. Each unit checks for the previous marker before running, preventing race conditions.

**Critical:** `install-user-packages.service` depends on `ConditionPathExists=/etc/ucore-autorebase/signed`. Without this, it could race with the signed rebase on boot 2 — both units would try to `rpm-ostree` and reboot simultaneously.

Once a unit has run, it disables itself (`systemctl disable ...` or a done marker), so it never fires again. The exceptions are the every-boot units: `bcache-reassemble.service` (reassembles the bcache set before local filesystems — without it, the `/var/mnt/cached-storage` mount fails after the first reboot) and `wol-enable.service` (enables Wake-on-LAN).

## File Structure

```
ignition-files/
├── butane.sh                     # Transpilation wrapper
├── README.md                     # This file
├── nevua-ketana.bu               # Per-machine butane config
├── setup-bcache.sh               # Machine-specific: one-shot bcache setup (embedded via local:)
├── bcache-reassemble.sh          # Machine-specific: bcache reassembly on every boot (embedded via local:)
├── llama-server.container        # Machine-specific: podman quadlet (embedded via local:)
├── llama-server-config.ini       # Machine-specific: llama.cpp preset config (embedded via local:)
└── llama-server-firewall.service # Machine-specific: firewalld rule for port 8001 (embedded via local:)
```

Each `.bu` file is self-contained. Within each file, sections are tagged as **generic** or **machine-specific** via comments:

- **Generic** — shared across all machines (ucore autorebase, package installs, user setup). Copy these into new machine files.
- **Machine-specific** — unique to one machine (disk device IDs, bcache, hostname, WoL interface). These change per box.

### Why not split into multiple files?

Butane has no `include` or inheritance mechanism. Any composability requires custom merge tooling, which adds complexity for 1–3 machines. The plan is to stay single-file per machine until a second or third box makes copy-paste painful — at which point a `yq`-based merge script is the right step up.

## Adding a New Machine

1. Copy an existing `.bu` file as a starting point
2. Change `passwd.users[0].password_hash` and `ssh_authorized_keys`
3. Update machine-specific sections in the `.bu`:
   - `storage.files` — hostname, WoL script interface
   - `systemd.units` — bcache units, WoL service
4. Update the machine-specific helper scripts (embedded into the `.bu` via
   `local:` references):
   - `setup-bcache.sh` — one-shot bcache setup (device IDs, mount point, policy)
   - `bcache-reassemble.sh` — every-boot bcache reassembly
   - ⚠️ The bcache device IDs (the by-id paths for the cache NVMe and the
     backing HDD) appear in **both** scripts — update both.
5. Remove any units/files that don't apply (e.g. no bcache? remove
   `setup-bcache.service`, `bcache-reassemble.service`, and both scripts)
6. Transpile: `./butane.sh new-machine.bu new-machine.ign`

## Butane/Ignition Basics

- **Butane** (`.bu`) — human-friendly YAML. Transpiled into Ignition JSON.
- **Ignition** (`.ign`) — machine-readable JSON. Consumed by FCOS at first boot.
- Ignition is **not** a configuration management tool. It only runs once, at provisioning. After that the OS is immutable (ostree-based). Use `rpm-ostree`, `systemd`, or a proper config management tool for ongoing changes.
- `local:` file references in butane are resolved at **transpilation time** (the file is embedded as base64 into the `.ign`). They are not fetched at boot.
- `source:` (remote) references are fetched at **boot time** over HTTP/HTTPS.
