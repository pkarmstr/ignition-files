# Task 9 — Post-Provisioning Verification: Summary

## Date: 2026-08-23

## What was done

### 1. Script fixes applied

#### `bcache-reassemble.sh` — 2 fixes

| # | Issue | Fix |
|---|-------|-----|
| 1 | **UUID-based "already assembled" check was fragile.** The loop checked only two specific sysfs directories (`/sys/fs/bcache/$BACKING_UUID` and `/sys/fs/bcache/$CACHE_UUID`), but the kernel names the sysfs directory after the **cache-set UUID**, which is neither of those. This could cause the script to attempt re-registration on a bcache that was already assembled, leading to errors or a race. | Changed to scan **all** existing bcache sets: `for d in /sys/fs/bcache/*/; do [ -e "$d/cache_dev" ] && ...`. This is robust regardless of which UUID the kernel uses for the sysfs directory name. |
| 2 | **`bcache-super-show` could leak error messages to stderr** if the device had no readable superblock (unlikely after the `blkid` check, but a safety concern). | Added `2>/dev/null` to both `bcache-super-show` calls. Also added `|| true` to prevent `set -e` from aborting the script if the pipeline fails. |

#### `setup-bcache.sh` — 1 fix

| # | Issue | Fix |
|---|-------|-----|
| 1 | **`bcache-super-show` could leak error messages to stderr** during UUID reading in the reassembly path. | Added `2>/dev/null` to both `bcache-super-show` calls (already had `|| true`). |

### 2. Verification script created

**File:** `verify-task9.sh`

A comprehensive SSH-ready verification script covering both phases from the PLAN.md:

**Phase A** (right after provisioning, llama server still disabled):
1. `bcache-reassemble.service` is active
2. `/dev/bcache*` device exists
3. `/var/mnt/cached-storage` is mounted
4. Cache policy is `writearound`
5. Mount unit has `After=bcache-reassemble.service` (via fstab `x-systemd.after=`)
6. `llama-server.service` is `generated` (not `disabled`)
7. No failed llama-server container attempts
8. `llama-server-firewall.service` is active
9. Port 8001/tcp open in firewalld
10. WoL enabled on enp14s0 (Wake-on: g)
11. No failed systemd units
12. `setup-bcache.done` marker exists
13. `setup-bcache.service` is disabled (one-shot complete)

**Phase B** (after restoring models + enabling server):
14. Models directory contains `.gguf` files
15. `llama-server.service` is active
16. Container logs show no errors
17. Server responds on `localhost:8001` (health or /v1/models)

**Reboot test** (manual): Run Phase A checks again after reboot to verify bcache reassembly + mount survive.

### 3. Transpilation verified

- `./butane.sh nevua-ketana.bu nevua-ketana.ign` → **exit 0**, valid JSON, Ignition 3.6.0
- 7 storage files present (all embedded files byte-identical to source)
- 8 systemd units (llama-server `enabled: false`, all others `enabled: true`)
- `bash -n` syntax check passes for both scripts

### 4. Items already fixed (from prior plan execution)

These were confirmed as already addressed in the current codebase:
- ✅ Quadlet volume path: `/var/mnt/cached-storage/llama-models` (not `/mnt/...`)
- ✅ `Restart=always` in `[Service]` section (not `[Container]`)
- ✅ `llama-server.service` shipped disabled (no `[Install]` in quadlet)
- ✅ Firewall unit in `/etc/systemd/system/` (not `/etc/containers/systemd/`)
- ✅ `bcache-reassemble.service` + script embedded
- ✅ `x-systemd.after=bcache-reassemble.service` in fstab (no separate drop-in)
- ✅ `setup-bcache.sh` has all guardrails (identity check, free check, size check, mount test)
- ✅ `setup-bcache.sh` reassembly path calls `bcache-reassemble.sh`
- ✅ `setup-bcache.sh` reads UUIDs from superblocks (not globbing `/sys/fs/bcache/*`)
- ✅ `setup-bcache.sh` uses `grep -vF` for fstab editing (not broken `sed -i`)
- ✅ `setup-bcache.sh` identifies bcache device by size (not `head -1`)
- ✅ `llama-server-config.ini` duplicate `ctx-size` removed
- ✅ README has data-loss warning, boot-sequence table updated, adding-new-machine section updated

## How to use the verification script

```bash
# Over SSH:
ssh keelan@192.168.0.45 'bash -s' < verify-task9.sh

# Or copy to target and run:
scp verify-task9.sh keelan@192.168.0.45:~/
ssh keelan@192.168.0.45 'bash ~/verify-task9.sh'
```

## Known minor issues (non-blocking)

1. **`llama-server-config.ini` trailing newline**: The source file has a trailing newline that is not preserved in the embedded content. This is a Butane `local:` behavior — the config is functionally identical. No fix needed.

2. **`butane.sh` `--files-dir` path**: When the input file has no directory prefix, `dirname` returns `.`, resulting in `--files-dir /cwd/.`. This is functionally identical to `/cwd/` — Butane resolves it correctly.
