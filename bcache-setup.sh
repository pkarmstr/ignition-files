#!/bin/bash
# bcache-setup.sh — state-aware bcache lifecycle engine (nevua-ketana)
#
# Runs on every boot via bcache-assemble.service, in two modes:
#
#   ASSEMBLE (default)  Non-destructive. Loads the bcache module,
#                       registers the existing bcache superblocks with
#                       the kernel, and waits for the cache set to
#                       attach. Survives every reboot.
#
#   INIT (fallback)     Destructive first-time provisioning. Runs only
#                       if assembly fails AND /var/lib/bcache-setup.done
#                       is absent: wipefs + make-bcache + mkfs.xfs, then
#                       writes the marker so INIT can never run twice.
#
# The volume is mounted by the native systemd unit
# var-mnt-cached\x2dstorage.mount — FCOS has no /etc/fstab, and this
# script never touches one.

set -euo pipefail

# Stable device IDs (from /dev/disk/by-id/)
BDEV=/dev/disk/by-id/wwn-0x5000039e58d0650e      # 20TB TOSHIBA HDWR62AU HDD (backing)
CDEV=/dev/disk/by-id/nvme-eui.00a07501e9cabc5c   # 1TB CT1000P510SSD8 NVMe (cache)
FS_UUID=7c1e6a42-9f3d-4b8e-a51c-2d0b8e4f6a37    # xfs metadata UUID (pinned; referenced by the mount unit)
DONE_MARKER=/var/lib/bcache-setup.done

# bcache-tools layout (Fedora): make-bcache and bcache-super-show live in
# /usr/bin; bcache-register is the udev helper in /usr/lib/udev (the same
# binary 69-bcache.rules runs).
MAKE_BCACHE=$(command -v make-bcache || true)
SUPER_SHOW=$(command -v bcache-super-show || true)
REGISTER=/usr/lib/udev/bcache-register

# Not yet layered (early boots of the provision chain): nothing to do.
if [[ -z $MAKE_BCACHE || -z $SUPER_SHOW ]]; then
  echo "WARNING: bcache-tools not installed yet; skipping bcache setup" >&2
  exit 0
fi

# Kernel name of a stable path (unstable, but only used for sysfs lookups)
kname() { basename "$(readlink -f "$1")"; }

# udev can lag early in boot; give the devices a moment to appear
wait_for_devices() {
  for _ in $(seq 1 30); do
    if [[ -b $BDEV && -b $CDEV ]]; then
      return 0
    fi
    sleep 1
  done
  echo "WARNING: $BDEV and/or $CDEV not present; skipping bcache setup" >&2
  return 1
}

# Register a device's bcache superblock with the kernel (the same action
# udev's 69-bcache.rules performs; done explicitly so we never race udev).
register() {
  "$REGISTER" "$1" || true
}

# The bcache device for this set is /dev/bcache<N> (no suffix); subdevices
# like /dev/bcache0-1 are excluded.
bcache_dev() {
  compgen -G '/dev/bcache*' | grep -E '^/dev/bcache[0-9]+$' | sort -n | head -n1
}

# Poll the backing device's bcache state until the cache set attaches.
# On timeout, continue degraded (the backing device works without its cache).
wait_for_attach() {
  local bstate
  for _ in $(seq 1 150); do
    bstate=$(cat "/sys/block/$(kname "$BDEV")/bcache/state" 2>/dev/null || true)
    case "${bstate:-}" in
      running | "caching data")
        echo "Cache set attached (state: $bstate)"
        return 0
        ;;
    esac
    sleep 4
  done
  echo "WARNING: cache set did not attach within timeout (state: ${bstate:-unknown}); continuing without cache" >&2
}

# Enforce the writearound policy: reads are served from the NVMe, writes go
# only to the HDD. Idempotent — only writes when the mode is not writearound.
ensure_writearound() {
  local cset buuid f mode
  cset=$("$SUPER_SHOW" "$BDEV" | awk '/^cset.uuid/{print $2}')
  buuid=$("$SUPER_SHOW" "$BDEV" | awk '/^dev.uuid/{print $2}')
  f="/sys/fs/bcache/${cset}/bdev/${buuid}/cache_mode"
  if [[ -f $f ]]; then
    mode=$(cat "$f")
    if [[ $mode != writearound ]]; then
      echo "Setting cache mode: $mode -> writearound"
      echo writearound > "$f" || echo "WARNING: failed to set cache mode" >&2
    fi
  fi
}

# --- Mode 1: non-destructive assembly (every boot) -------------------------
assemble() {
  if ! compgen -G '/dev/bcache*' >/dev/null; then
    # Nudge udev (69-bcache.rules auto-registers any superblock it finds),
    # then register both devices explicitly.
    udevadm trigger --action=change --subsystem-match=block 2>/dev/null || true
    register "$BDEV"
    register "$CDEV"

    for _ in $(seq 1 60); do
      if compgen -G '/dev/bcache*' >/dev/null; then
        break
      fi
      sleep 2
    done
  fi

  if ! compgen -G '/dev/bcache*' >/dev/null; then
    echo "ERROR: no /dev/bcache* device after registration attempt" >&2
    return 1
  fi

  wait_for_attach
}

# --- Mode 2: destructive first-time initialization (one-time) --------------
initialize() {
  echo "First-time initialization: formatting bcache (DESTROYS data on both devices)"

  # Size sanity checks (512-byte sector counts) so we never wipe the wrong device
  local bsectors csectors
  bsectors=$(cat "/sys/block/$(kname "$BDEV")/size")
  csectors=$(cat "/sys/block/$(kname "$CDEV")/size")
  if (( bsectors < 30000000000 || bsectors > 60000000000 )); then
    echo "ERROR: unexpected backing device size: $bsectors sectors" >&2
    exit 1
  fi
  if (( csectors < 1800000000 || csectors > 2100000000 )); then
    echo "ERROR: unexpected cache device size: $csectors sectors" >&2
    exit 1
  fi
  echo "backing: $bsectors sectors; cache: $csectors sectors"

  # wipefs destroys every recognized signature/superblock. No dd zeroing:
  # a 4GiB pass was pure NVMe wear — bcache does not require zeroed storage.
  sync
  wipefs -a "$BDEV"
  wipefs -a "$CDEV"
  sync

  echo "Creating bcache backing device..."
  "$MAKE_BCACHE" -B "$BDEV"

  # The cache device must share the backing device's cache-set UUID, or the
  # kernel will never attach the two (make-bcache -C generates a fresh one).
  local cset
  cset=$("$SUPER_SHOW" "$BDEV" | awk '/^cset.uuid/{print $2}')
  if [[ -z $cset ]]; then
    echo "ERROR: could not read backing device's cache-set UUID" >&2
    exit 1
  fi
  echo "Creating bcache cache device (cache set $cset)..."
  "$MAKE_BCACHE" -C --cset-uuid="$cset" "$CDEV"

  # Register both with the kernel
  register "$BDEV"
  register "$CDEV"

  for _ in $(seq 1 60); do
    if compgen -G '/dev/bcache*' >/dev/null; then
      break
    fi
    sleep 2
  done
  if ! compgen -G '/dev/bcache*' >/dev/null; then
    echo "ERROR: /dev/bcache* device did not appear" >&2
    exit 1
  fi

  ensure_writearound
  wait_for_attach

  local bdev
  bdev=$(bcache_dev)
  echo "Creating xfs on $bdev (uuid $FS_UUID)..."
  mkfs.xfs -f -m uuid="$FS_UUID" "$bdev"
  sync

  touch "$DONE_MARKER"
  echo "bcache initialization complete: $bdev (xfs UUID $FS_UUID)"
}

# --- main -------------------------------------------------------------------
main() {
  wait_for_devices || exit 0

  # The bcache module must be available for (re)registration
  if ! modprobe bcache 2>/dev/null; then
    echo "WARNING: bcache kernel module not available; skipping bcache setup" >&2
    exit 0
  fi
  if [[ ! -d /sys/fs/bcache ]]; then
    echo "WARNING: /sys/fs/bcache not mounted; skipping bcache setup" >&2
    exit 0
  fi

  # --- Mode 1: assembly (every boot) ---
  if assemble; then
    ensure_writearound
    echo "bcache assembled: $(compgen -G '/dev/bcache*' | tr '\n' ' ')"

    if [[ ! -f $DONE_MARKER ]]; then
      # Assembled but no marker: did first-time initialization complete?
      local bdev fstype
      bdev=$(bcache_dev)
      fstype=$(blkid -o value -s TYPE "$bdev" 2>/dev/null || true)
      if [[ $fstype == xfs ]]; then
        # Filesystem present, marker lost — restore it
        touch "$DONE_MARKER"
        echo "Restored lost marker $DONE_MARKER (xfs present on $bdev)"
      else
        echo "ERROR: bcache device assembled but has no xfs and no marker $DONE_MARKER;" \
             "first-time init is incomplete — manual intervention required" >&2
        exit 1
      fi
    fi
    exit 0
  fi

  # --- Assembly failed ---
  if [[ -f $DONE_MARKER ]]; then
    echo "ERROR: assembly failed but $DONE_MARKER exists; refusing destructive re-initialization" >&2
    exit 1
  fi

  # --- Mode 2: first-time initialization (destructive, one-time) ---
  initialize
}

main
