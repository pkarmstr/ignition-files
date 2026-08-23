# Handoff Plan — nevua-ketana provisioning fixes

**Date:** 2026-08-23
**Reviewer:** pi coding agent (reviewed repo + live-verified against target via SSH)
**Target machine:** `keelan@192.168.0.45` (nevua-ketana)

## Context

This repo provisions an FCOS headless workstation via Butane → Ignition. The machine
currently runs an **old** provisioning (ucore-minimal:stable-nvidia, FCOS 44) plus a
**manual stopgap** for the llama.cpp server (manual HDD mount + `podman-compose` from
`/var/opt/llama-cpp/docker-compose.yml`). The new `.bu` has **never been applied** —
notably, `setup-bcache.sh` has **never run** (bcache-tools was never installed, no
bcache superblocks exist). Treat all bcache code as untested.

> **Update 2026-08-23:** user confirmed all data on the 20 TB HDD is backed up —
> wiping is approved. The llama-server quadlet will ship **disabled** until the user
> manually restores the models to the new bcache mount (see Tasks 2, 8, 9).

### Verified facts (do not re-verify, do not "fix" these)

| Fact | Value |
|---|---|
| Target OS | FCOS 44 (44.20260802.3.1), ucore-minimal:stable-nvidia, ignition 2.26.0, systemd 259, podman 5.8.4 |
| GPUs | 2× RTX PRO 4000 Blackwell 24 GB → `/dev/nvidia0`, `/dev/nvidia1` exist (quadlet `AddDevice` list is correct) |
| RAM | 30 GB |
| System disk | `nvme1n1` (512 GB, FCOS) |
| bcache cache disk | `nvme0n1` (1 TB Samsung CT1000P510SSD8) — **currently holds 5 Windows partitions, will be wiped** |
| bcache backing disk | `sda` (20 TB Toshiba) — **currently holds 2.6 TB of data: `datasets/`, `hf-cache/`, `llama-models/`, `safetensors-models/` (mounted at `/var/mnt/20tb-hdd`); will be wiped — data backed up by user 2026-08-23, wipe approved** |
| by-id symlinks | `nvme-CT1000P510SSD8_2537E9CABC5C` → `/dev/nvme0n1`, `wwn-0x5000039e58d0650e` → `/dev/sda` (both correct; note a duplicate `..._1` symlink also exists — a udev quirk, ignore) |
| Base image already contains | `ethtool`, `firewalld`, `podman` (NOT layered — verified via `rpm-ostree status`; do not add to install list) |
| Layered packages (old) | `btop neovim tree` |
| `sudo` group | exists (GID 16) — the `groups: [wheel, sudo]` in the `.bu` is fine |
| WoL | `enp14s0` supports `pumbg`, currently `Wake-on: d` (disabled) |
| Firewall | firewalld active, `8001/tcp` already open in `FedoraServer` zone (manual) |
| llama image flag | `--models-preset /config/llama-server-config.ini` **confirmed working** on `ghcr.io/ggml-org/llama.cpp:server-cuda13` (live container serving at ~35 tok/s) |
| Old rebase markers | `/etc/ucore-autorebase/{unverified,signed}` both exist → rebase chain is a no-op on in-place re-provision |
| Old done markers | `/var/lib/install-user-packages.done` and `/var/lib/setup-bcache.done` do **not** exist |
| bcache auto-assembly | **does not exist** — no kernel auto-assembly, no udev rule, no systemd unit shipped by anything on the system |
| butane | `quay.io/coreos/butane:latest` = v0.29.0 (built 2026-07-28). fcos variant 1.7.0 → ignition config 3.6.0, which FCOS 44's ignition 2.26.0 supports (butane v0.27.0 stabilized fcos 1.7.0 for FCOS 44) |

---

## Data note (updated 2026-08-23)

The first run of `setup-bcache.sh` performs **full setup** (no existing bcache
superblocks) → `wipefs` + `make-bcache` + `mkfs.ext4` on **both** `nvme0n1` and `sda`.

**Backup status: done** — user confirmed all data on the 20 TB HDD (2.6 TB) is backed
up; the wipe is approved. After provisioning, the models must be restored to
`/var/mnt/cached-storage/llama-models` (Task 8). Until then the llama-server quadlet
stays disabled (Task 2).

---

## Task 1 — Fix `butane.sh` (broken against current butane image)

**Confirmed bug:** butane ≥ current `latest` rejects `local:` file references without
an explicit `--files-dir` (reproduced: `error[$.storage.files.1.contents.local]: local
file paths are relative to a files directory that must be specified with
-d/--files-dir`). The script only worked with an old cached image.

Changes:
1. Pass `--files-dir` pointing at the **input file's directory** (in-container path),
   placed **after** the user's passthrough args so it wins on duplicates:
   ```bash
   INPUT_DIR="$(dirname "$INPUT_FILE")"
   docker run --rm -v "$(pwd):/cwd:ro" "$BUTANE_IMAGE" \
     "${BUTANE_ARGS[@]}" --files-dir "/cwd/$INPUT_DIR" "/cwd/$INPUT_FILE" > "$TMP_OUT"
   ```
2. Pin the image: `BUTANE_IMAGE="${BUTANE_IMAGE:-quay.io/coreos/butane:v0.29.0}"`.
3. Write to a `mktemp` file and `mv` to `$OUTPUT_FILE` only on success (currently a
   failed run leaves a truncated/empty `.ign` behind).
4. Fail with a clear error if the output is empty or not valid JSON (e.g.
   `python3 -m json.tool` or `jq -e .` if available; keep it simple).
5. Check `command -v docker` up front with a helpful message.
6. Optionally inject `--strict` by default (README already recommends it).
7. Update the usage text: `--files-dir` is now managed by the script; remove the
   `--files-dir` passthrough example.
8. Reject absolute input paths or paths containing `..` (they break the `/cwd/...`
   mapping) — or resolve via `realpath` and verify the result is under `$(pwd)`.

**Verify:** `./butane.sh nevua-ketana.bu /tmp/t.ign` succeeds and produces valid JSON
(repro command from review: `docker run --rm -v $(pwd):/w:ro quay.io/coreos/butane:latest --strict --files-dir /w /w/nevua-ketana.bu` → exit 0, 10.4 KB, ignition 3.6.0).

## Task 2 — Fix `nevua-ketana.bu`

> **Executed 2026-08-23 (pi). Live-verified against the target; the plan's
> literal instructions needed four corrections, all verified on the machine
> (podman 5.8.4 / systemd 259):**
>
> 1. **Unit name is `llama-server.service`, not `llama-server.container.service`.**
>    Podman docs + live test: "a `$name.container` file creates a `$name.service`
>    unit" (suffix stripped). The old `.bu` entry (`llama-server.container.service`,
>    `enabled: true`) referenced a unit that never exists.
> 2. **`Restart=` is not supported in the quadlet `[Container]` section** — the
>    quadlet-generator rejects it (`unsupported key 'Restart' in group
>    'Container'`) and generates **no unit at all**. It belongs in the quadlet's
>    `[Service]` section (passed through to the generated unit, verified).
> 3. **`unless-stopped` is not a systemd value** — it's a docker restart policy.
>    systemd 259: `Failed to parse Restart=unless-stopped, ignoring: Invalid
>    argument` (silently → `Restart=no`). Used **`Restart=always`**, systemd's
>    equivalent of docker `unless-stopped` (restart on crash; no restart after an
>    explicit `systemctl stop`).
> 4. **"Ship disabled" = remove `[Install]` from the quadlet.** The generator
>    auto-applies `[Install]` on every generation (wants symlink → starts at boot),
>    and `systemctl enable`/`disable` **do not work** on generated units ("transient
>    or generated" / no-op). Verified: quadlet without `[Install]` generates a unit
>    with no wants symlink (ships stopped); with `[Install]` it auto-enables.
>    The `.bu` entry is `llama-server.service: enabled: false` — a verified-safe
>    no-op (Ignition's `DisableUnit` skips units that `is-enabled` reports as not
>    enabled).
> 5. **Bonus bug found: the firewall unit was placed in `/etc/containers/systemd/`,
>    which is NOT in systemd's unit search path** (verified with a probe unit —
>    invisible to `systemctl`, so `enabled: true` could never take effect and port
>    8001 would never open). Moved to `/etc/systemd/system/llama-server-firewall.service`
>    and fixed its `Before=llama-server.service` reference.
> 6. **Later enablement is NOT `systemctl enable`** (fails on generated units).
>    Use the drop-in procedure documented in `llama-server.container` (also in Task 8
>    below). Note `systemctl is-enabled llama-server.service` reports **`generated`**
>    (exit 0), not `disabled`.
>
> Preset mechanics verified end-to-end from the old provisioning's boot journals:
> Ignition 2.26 writes `/etc/systemd/system-preset/20-ignition.preset` (no
> `systemctl enable` calls); systemd applies it at boot (wants symlinks created),
> which is how the old ucore chain started. The new config follows the same proven
> pattern.

1. **BUG (high): quadlet volume path mismatch.** `llama-server.container` has
   `Volume=/mnt/cached-storage/llama-models:/models:ro` but the bcache mount point is
   `/var/mnt/cached-storage` (see `setup-bcache.sh` `MOUNT_POINT` and the
   `storage.directories` entry). Podman auto-creates the missing host dir, so the
   container would silently start with an **empty** `/models` and every preset would
   fail to load. Fix: `Volume=/var/mnt/cached-storage/llama-models:/models:ro`.
2. **Add `Restart=unless-stopped`** to the quadlet `[Container]` section (matches the
   old compose `restart: unless-stopped`; quadlet default is no restart, so a runtime
   crash would leave the server down). Verify the value is accepted by podman 5.8
   quadlet (`on-failure` is a safe fallback).
3. **Ship the llama quadlet disabled.** In `systemd.units`, set
   `llama-server.container.service` to `enabled: false` (the file is still written to
   `/etc/containers/systemd/`, so the unit exists and can be enabled later with one
   command). Reason: the model data is wiped with the backing disk and must be
   restored to `/var/mnt/cached-storage/llama-models` first. Keep
   `llama-server-firewall.service` **enabled** — it is idempotent and harmless while
   nothing listens on 8001, and it makes later enablement a single
   `systemctl enable --now llama-server.container.service`.
4. **Add `bcache-reassemble.service` + script** (see Task 3) — embed
   `bcache-reassemble.sh` via `local:` like `setup-bcache.sh`, and add the unit with
   `enabled: true`.
5. Add to `wol-enable.service` unit: `ConditionPathExists=/sys/class/net/enp14s0`
   so a copy-paste to a machine without that NIC fails silently instead of spamming
   the journal every boot.
6. Cosmetic: `/etc/ucore-autorebase` directory mode `0754` → `0755`.
7. Do **not** change: user groups, install package list, rebase chain, by-id device
   paths, image tag, port, `AddDevice` list (all verified correct above).

## Task 3 — New: `bcache-reassemble.sh` + `bcache-reassemble.service` (missing reboot support)

> **Update 2026-08-23 (after Task 4):** the mount drop-in below was replaced by
> `x-systemd.after=bcache-reassemble.service` in the fstab line that
> `setup-bcache.sh` writes (the fstab generator maps it to `After=` on the
> generated mount unit). Same ordering, one fewer file, and the `.bu` no longer
> ships a drop-in for a unit that doesn't exist until first setup.

**BUG (high, functional):** the kernel does **not** auto-assemble bcache on boot (no
udev rule, no shipped unit — verified). `setup-bcache.service` self-disables after its
one run, so after the **first reboot** `/dev/bcache0` no longer exists and the fstab
mount of `/var/mnt/cached-storage` fails every boot → llama models inaccessible.
This machine is headless, so this would be a silent, user-visible outage.

New file `bcache-reassemble.sh` (embed into `.bu` at `/usr/local/bin/bcache-reassemble.sh`, mode 0755):

```bash
#!/bin/bash
# Reassemble bcache on boot. The kernel does not auto-assemble bcache sets.
# Exits 0 quietly when no bcache is present (safe on machines without bcache).
set -euo pipefail

CACHE_DEV="/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C"
BACKING_DEV="/dev/disk/by-id/wwn-0x5000039e58d0650e"

# Wait for udev by-id symlinks (up to 30 s)
for _ in $(seq 1 30); do
  [ -b "$CACHE_DEV" ] && [ -b "$BACKING_DEV" ] && break
  sleep 1
done
[ -b "$CACHE_DEV" ] && [ -b "$BACKING_DEV" ] || exit 0

# Only proceed if both devices carry bcache superblocks
blkid -p "$CACHE_DEV" 2>/dev/null | grep -q "TYPE=bcache" || exit 0
blkid -p "$BACKING_DEV" 2>/dev/null | grep -q "TYPE=bcache" || exit 0

modprobe bcache || exit 1

CACHE_UUID=$(bcache-super-show "$CACHE_DEV" | grep -m1 '^UUID:' | awk '{print $2}')
BACKING_UUID=$(bcache-super-show "$BACKING_DEV" | grep -m1 '^UUID:' | awk '{print $2}')
[ -n "$CACHE_UUID" ] && [ -n "$BACKING_UUID" ] || { echo "ERROR: could not read bcache UUIDs" >&2; exit 1; }

# Already assembled?
for d in "/sys/fs/bcache/$BACKING_UUID" "/sys/fs/bcache/$CACHE_UUID"; do
  [ -e "$d/cache_dev" ] && { echo "bcache already assembled"; exit 0; }
done

# Register cache with backing device (standard reassembly procedure).
# Try the backing's own uuid first, then the cache-set uuid, then any detached backing entry.
if [ -f "/sys/fs/bcache/$BACKING_UUID/register" ]; then
  echo "$CACHE_UUID" > "/sys/fs/bcache/$BACKING_UUID/register"
elif [ -f "/sys/fs/bcache/$CACHE_UUID/register" ]; then
  echo "$CACHE_UUID" > "/sys/fs/bcache/$CACHE_UUID/register"
else
  registered=0
  for d in /sys/fs/bcache/*/; do
    if [ -e "$d/backing_dev" ] && [ ! -e "$d/cache_dev" ] && [ -f "$d/register" ]; then
      echo "$CACHE_UUID" > "$d/register"
      registered=1
      break
    fi
  done
  [ "$registered" -eq 1 ] || { echo "ERROR: no detached bcache backing entry found in /sys/fs/bcache" >&2; exit 1; }
fi

# Wait for the combined device, identified by size (bcache presents backing capacity)
BACKING_SECTORS=$(blockdev --getsz "$BACKING_DEV")
for _ in $(seq 1 15); do
  for d in /dev/bcache*; do
    [ -b "$d" ] || continue
    [ "$(blockdev --getsz "$d")" -eq "$BACKING_SECTORS" ] && { echo "bcache reassembled: $d"; exit 0; }
  done
  sleep 1
done
echo "ERROR: bcache device did not appear after registration" >&2
exit 1
```

Notes for the implementer:
- Verify `bcache-super-show` output format on the real machine after first setup
  (expect a `UUID: <uuid>` line; adjust the grep if needed).
- The sysfs keying of `/sys/fs/bcache/<uuid>/` after assembly may be the cache-set
  uuid rather than the backing's own uuid — the script tries both plus a fallback
  scan, which covers it. Confirm behavior in the reboot test (Task 7).

New unit in the `.bu` (`enabled: true`, runs every boot):

```ini
[Unit]
Description=Reassemble bcache devices
DefaultDependencies=no
After=local-fs-pre.target systemd-udevd.service
Before=local-fs.target
Wants=local-fs-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
StandardOutput=journal+console
ExecStart=/usr/local/bin/bcache-reassemble.sh

[Install]
WantedBy=local-fs.target
```

**Also add a mount drop-in** so the fstab-generated mount unit waits for reassembly
(two units both `Before=local-fs.target` would otherwise race). Add to `.bu`
`storage.files`:

```
- path: /etc/systemd/system/var-mnt-cached-storage.mount.d/after-bcache-reassemble.conf
  mode: 0644
  overwrite: true
  contents:
    inline: |
      [Unit]
      After=bcache-reassemble.service
```

## Task 4 — Fix `setup-bcache.sh`

This script has never run. Confirmed bugs + missing guardrails:

1. **BUG: stale-registration cleanup is dead code.** `cache_dev`/`backing_dev` under
   `/sys/fs/bcache/<uuid>/` are **symlinks to directories**, so `[ -f ... ]` is always
   false; the file is `register`, not `registration`. The loop never executes.
   Replace with (only if you keep the cleanup at all — see #2, it may become
   unnecessary):
   ```bash
   for bc_dir in /sys/fs/bcache/*/; do
     for kind in backing_dev cache_dev; do
       [ -e "${bc_dir}${kind}" ] || continue
       echo stopped > "$(readlink -f "${bc_dir}${kind}")/bcache/state" 2>/dev/null || true
     done
   done
   ```
2. **BUG: UUID discovery globs `/sys/fs/bcache/*`** — stale entries from a crashed
   earlier attempt overwrite `CACHE_UUID`/`BACKING_UUID` (last match wins). Replace
   with direct superblock reads (bcache-tools is in the install list):
   ```bash
   CACHE_UUID=$(bcache-super-show "$CACHE_DEV" | grep -m1 '^UUID:' | awk '{print $2}')
   BACKING_UUID=$(bcache-super-show "$BACKING_DEV" | grep -m1 '^UUID:' | awk '{print $2}')
   ```
3. **BUG: `wait_for_bcache_dev` picks `ls /dev/bcache* | head -1`** — wrong device if
   multiple bcache devices exist (e.g. stale one from a failed attempt). Identify the
   device by (a) appearing **after** the attach step and (b) `blockdev --getsz`
   equal to `BACKING_SECTORS` (bcache presents the backing's capacity). See the
   pattern in Task 3.
4. **BUG: `sed -i "/${MOUNT_POINT}/d" /etc/fstab` is broken** — confirmed:
   `sed: -e expression #1, char 26: expected newer version of sed` (unescaped `/` in
   the pattern), and under `set -e` the script dies. Use
   `grep -vF "$MOUNT_POINT" /etc/fstab > tmp && mv tmp /etc/fstab` or
   `sed -i "\#${MOUNT_POINT}\#d"`.
5. **BUG: the "existing bcache" reassembly path never reassembles** — it runs
   `udevadm trigger` (which does not assemble bcache) and then waits, so it always
   times out in the scenario it exists for. Make it call the same reassembly logic as
   Task 3 (extract into a shared function sourced by both scripts, or just invoke
   `/usr/local/bin/bcache-reassemble.sh` and then verify).
6. **Missing guardrail (data loss): no check that devices are free before wiping.**
   In an in-place re-provision where the old HDD mount unit survived, this script
   would `wipefs` a disk with a mounted 2.6 TB filesystem. Before any wipe, for both
   devices and all their partitions:
   - `findmnt --source <dev>` must be empty (device and each partition),
   - `/sys/block/<dev>/holders` must be empty (no LVM/dm-crypt/md users).
   Fail loudly otherwise.
7. **Missing guardrail: identity check.** Print `readlink -f` of both by-id paths at
   start, and verify the resolved device's model/serial matches expectations
   (NVMe: `$(readlink -f $CACHE_DEV)/device/model` contains `CT1000P510SSD8`;
   SATA: `$(readlink -f $BACKING_DEV)/device/model` is non-empty and logged).
   Fail on mismatch.
8. **Missing guardrail: size check before mkfs.** After attach, verify
   `blockdev --getsz $BCACHE_DEV -eq $BACKING_SECTORS` before `mkfs.ext4` (bcache
   must present the backing's capacity; a mismatch means we'd format the wrong device).
9. **Missing guardrail: test the mount before declaring success.** After writing the
   fstab entry: `mount "$MOUNT_POINT"` (fail on error), optionally `umount` it, and
   only then `touch /var/lib/setup-bcache.done` + disable the unit.
10. Conciseness: use `$DESIRED_POLICY` in the full-setup path instead of the
    hardcoded `"writearound"` string; drop the now-redundant `udevadm trigger`/`settle`
    noise where the shared reassembly handles it.

## Task 5 — `llama-server-config.ini` cleanup (cosmetic)

> **Executed 2026-08-23 (pi):**
>
> 1. Removed the duplicate `ctx-size = 262144` from `[Qwen3.6-27B-Dense-27GB]`.
>    Verified: 0 duplicate keys remain across all 27 sections.
> 2. **Correction to the plan:** `--tools all` in the quadlet `Exec=` is **required** —
>    it was kept (removal was rejected). Verified against llama.cpp source (original
>    preset PR #17859 + current master): the tools API (`/tools` on the published
>    port) is served by the **router** process, which only reads its own CLI params
>    (`params.server_tools`). The preset `[*]` section cascades into the **child
>    model processes' args only** — it never enables the router's tools API, so a
>    server started without the CLI flag returns 403 on `/tools` regardless of the
>    ini. Do not remove `--tools all` from `Exec=`.
> 3. Kept the commented-out `#mmproj = ...` lines (plan explicitly allows; they
>    document which mmproj file each preset would use, and the same model families
>    have active mmproj lines elsewhere in the file).
> 4. Observation (no change made): `tools = all` in the ini `[*]` section is
>    redundant — child processes inherit the router's CLI args — but harmless and
>    part of the live-verified setup, so it was left as-is.

1. `[Qwen3.6-27B-Dense-27GB]` has `ctx-size = 262144` **twice** — remove the duplicate.
2. Optional: remove the redundant `--tools all` from the quadlet `Exec=` (the `[*]`
   section already sets `tools = all`).
3. Optional: remove or resolve the commented-out `#mmproj = ...` lines
   (`Qwen3.8-27B`, `Qwen3.6-27B-Dense-33GB`, `Qwen3.6-35B-MoE-21GB/36GB/BF16-62GB`) —
   keep if the mmproj files may appear later.

## Task 6 — README updates

1. `butane.sh` section: `--files-dir` is now automatic (resolved from the input
   file's directory); document the pinned image default and the `BUTANE_IMAGE`
   override.
2. Boot-sequence table: add a row for `bcache-reassemble.service` (runs at **every**
   boot, before local filesystems) — the "4-boot chain" table currently implies
   bcache survives reboots, which it does not without this unit.
3. Add a prominent **data-loss warning**: first bcache setup wipes the 1 TB NVMe and
   the 20 TB backing disk; back up data elsewhere first; models go to
   `/var/mnt/cached-storage/llama-models` after setup.
4. "Adding a New Machine": mention the new machine-specific files
   (`setup-bcache.sh`, `bcache-reassemble.sh`) and that the bcache
   device IDs appear in **two** scripts.

## Task 7 — Transpile + static verification

1. `./butane.sh nevua-ketana.bu nevua-ketana.ign` (strict) — must succeed.
2. Sanity-check the `.ign` JSON: all 7 storage files present, 8 systemd units
   (the existing 7 + `bcache-reassemble.service`), quadlet volume path is
   `/var/mnt/cached-storage/llama-models`.
3. `bash -n setup-bcache.sh bcache-reassemble.sh` (shell syntax).
4. Re-read the final `.bu` end-to-end for consistency (mount point string must match
   across: `storage.directories`, `setup-bcache.sh`, quadlet volume).

## Task 8 — Provisioning runbook (user executes, agent assists)

1. ~~Back up the 20 TB HDD data~~ — **done** (user confirmed 2026-08-23). Wiping is
   approved; no further backup steps.
2. Remove the old manual container so the quadlet's `ContainerName=llama-server`
   doesn't collide (only relevant for **in-place** re-provision; a fresh install wipes
   `/var`): on the target, `podman rm -f llama-server`.
3. Provision with the new `.ign` — either:
   - **Fresh install** from ISO + `coreos-installer` (cleanest; wipes system disk
     `nvme1n1` only), or
   - **In-place** ignition re-run (rebase chain no-ops due to existing markers;
     `install-user-packages` + `setup-bcache` still run).
   Either way the chain is: (fresh) unsigned rebase → signed rebase → package install
   (adds `bcache-tools`) → bcache setup (wipes + formats both disks, fstab entry).
   The llama-server quadlet is **disabled** in the new config (Task 2) — the machine
   boots without the llama server until the data is restored.
4. After bcache setup completes: restore models to
   `/var/mnt/cached-storage/llama-models/` (the quadlet expects exactly this path).
   The other backed-up dirs can go under `/var/mnt/cached-storage/` as well.
5. Enable the llama server. `systemctl enable` does **not** work on generated
   quadlet units — use the drop-in (see the comments in `llama-server.container`):
   ```bash
   sudo mkdir -p /etc/containers/systemd/llama-server.container.d
   sudo printf '[Install]\nWantedBy=multi-user.target\n' \
     | sudo tee /etc/containers/systemd/llama-server.container.d/enable.conf
   sudo systemctl daemon-reload
   sudo systemctl start llama-server.service
   ```
   (the firewall unit is already enabled, so port 8001 is already open).
6. **Reboot** (the critical test — see Task 9): bcache reassembly, the mount, and the
   llama server should all come back automatically.

## Task 9 — Post-provisioning verification checklist

Run over SSH on the target.

**Phase A — right after provisioning (llama server still disabled, data not yet restored):**

- [ ] `systemctl status bcache-reassemble.service` — active.
- [ ] `ls /dev/bcache*` exists; `findmnt /var/mnt/cached-storage` shows the ext4
      bcache mount; `cat /sys/block/bcache0/bcache/cache_policy` = `writearound`;
      `systemctl cat var-mnt-cached-storage.mount` shows
      `After=bcache-reassemble.service` (from the fstab `x-systemd.after=`).
- [ ] `systemctl is-enabled llama-server.service` → `generated` (expected for a
      quadlet unit without `[Install]`; **not** `disabled`); unit inactive — no
      failed container attempts.
- [ ] `systemctl status llama-server-firewall.service` — active;
      `sudo firewall-cmd --list-ports` includes `8001/tcp`.
- [ ] `sudo ethtool enp14s0 | grep -i "wake-on"` shows `g` enabled
      (e.g. `Wake-on: g`); optionally test WoL by powering off and sending a magic
      packet.
- [ ] `systemctl list-units --state=failed` — empty.
- [ ] **Reboot** → re-run the above; bcache reassembly + mount survive the reboot
      (the make-or-break test for Task 3).

**Phase B — after restoring models and enabling the server via the drop-in
procedure (Task 8 step 5; `systemctl enable` does not work on generated
quadlet units):**

- [ ] `ls /var/mnt/cached-storage/llama-models` contains the restored models.
- [ ] `systemctl status llama-server.service` — active;
      `podman logs llama-server | tail` shows model loading, no missing-file errors.
- [ ] `curl -s localhost:8001/health` (or `/v1/models`) responds.
- [ ] **Reboot** → bcache reassembles, mount comes up, llama server starts
      automatically (full end-to-end test).
- [ ] Crash-resilience (optional): `podman stop llama-server` → unit should restart
      the container (`Restart=always`).
- [ ] Re-provision safety (optional, later): confirm
      `setup-bcache.service` no-ops via its done marker.

## Optional / out of scope (noted, not required)

- Firewall rule opens `8001/tcp` to all sources; a rich rule restricting to the LAN
  subnet is possible if desired.
- Quadlet `AddDevice` list hardcodes `nvidia0`/`nvidia1` — fine for this box; would
  need editing if GPUs change.
- The 62 GB BF16 preset (`Qwen3.6-35B-MoE-BF16-62GB`) exceeds the 48 GB total VRAM
  and will spill to CPU — user's choice, just noting.
- In-place re-provision leaves old `/etc/systemd/system` units behind (`dnsmasq`,
  `zed`, `zfs-*`, old `ucore-*` unit files — all inert). Worth a one-time audit if
  re-provisioning in place.
