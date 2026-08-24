#!/bin/bash
# Set up bcache on nevua-ketana: the 1 TB NVMe (nvme0n1) as a read cache for
# the 20 TB HDD (sda), writearound policy, ext4, mounted at
# /var/mnt/cached-storage via fstab.
#
# Two paths:
#   * both devices already carry bcache superblocks -> reassemble (same logic
#     as bcache-reassemble.service) and verify policy + fstab
#   * otherwise -> full setup: wipe signatures, make-bcache, attach, mkfs
#
# Guardrails (this script has never run before; be paranoid):
#   * identity check: the resolved by-id devices must match expected models
#   * free check: refuse to wipe a device (or its partitions) that is mounted
#     or held (LVM / dm-crypt / md / bcache)
#   * size check: bcache must present the backing's capacity before mkfs
#   * mount test: the mount must work before the done marker is written
set -euo pipefail

CACHE_DEV="/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C"
BACKING_DEV="/dev/disk/by-id/wwn-0x5000039e58d0650e"
CACHE_EXPECTED_MODEL="CT1000P510SSD8"
DESIRED_POLICY="writearound"
MOUNT_POINT="/var/mnt/cached-storage"
# x-systemd.after= makes the fstab-generator's mount unit wait for bcache
# reassembly (both units are otherwise Before=local-fs.target and would race).
FSTAB_OPTIONS="defaults,noatime,x-systemd.after=bcache-reassemble.service"

# --- Helpers ---

# Print the hardware model string for a block device (e.g. /dev/sda).
# Works for both SATA/SCSI and NVMe via /sys/block/<name>/device/model.
# sysfs pads the value with trailing spaces; strip them.
get_device_model() {
  local name
  name=$(basename "$1")
  sed -e 's/[[:space:]]*$//' "/sys/block/$name/device/model" 2>/dev/null || true
}

# Find a /dev/bcache* device that presents the backing device's capacity
# (bcache presents the backing's size). Optional $1: space-separated list of
# devices to ignore (e.g. ones that existed before our attach step).
find_bcache_dev() {
  local skip=" ${1:-} "
  local d
  for d in /dev/bcache*; do
    [ -b "$d" ] || continue
    case "$skip" in *" $d "*) continue ;; esac
    if [ "$(blockdev --getsz "$d")" -eq "$BACKING_SECTORS" ]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

# Poll find_bcache_dev until it succeeds or times out.
wait_for_bcache_dev() {
  local timeout="${1:-15}" skip="${2:-}"
  local start=$SECONDS dev
  while [ $(( SECONDS - start )) -lt "$timeout" ]; do
    if dev=$(find_bcache_dev "$skip"); then
      printf '%s\n' "$dev"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Timed out waiting for bcache device (${timeout}s); expected /dev/bcache* of size $BACKING_SECTORS sectors." >&2
  return 1
}

# Remove fstab lines that mention the mount point (fixed-string match).
# (The old `sed -i "/${MOUNT_POINT}/d"` was broken: unescaped '/' in pattern.)
remove_fstab_mountpoint() {
  local tmp
  tmp=$(mktemp /etc/fstab.tmp.XXXXXX)
  grep -vF "$MOUNT_POINT" /etc/fstab > "$tmp" || true
  chmod 0644 "$tmp"
  mv -f "$tmp" /etc/fstab
}

# Refuse to wipe a device that is mounted or has active holders
# (LVM / dm-crypt / md / bcache). Checks the whole device and every
# partition. Data-loss guardrail.
verify_device_free() {
  local dev="$1" real name part pdev
  real=$(readlink -f "$dev")
  name=$(basename "$real")
  if findmnt --source "$real" >/dev/null 2>&1; then
    echo "ERROR: $dev ($real) is currently mounted. Refusing to wipe." >&2
    exit 1
  fi
  if [ -s "/sys/block/$name/holders" ]; then
    echo "ERROR: $dev ($real) has active holders: $(tr '\n' ' ' < "/sys/block/$name/holders"). Refusing to wipe." >&2
    exit 1
  fi
  # Partitions: NVMe uses <name>p<N>, SATA/SCSI uses <name><N>
  # (globs unquoted on purpose; no match -> literal -> skipped by [ -e ])
  for part in /sys/block/$name/${name}p* /sys/block/$name/${name}[1-9]*; do
    [ -e "$part" ] || continue
    pdev="/dev/$(basename "$part")"
    if findmnt --source "$pdev" >/dev/null 2>&1; then
      echo "ERROR: partition $pdev is currently mounted. Refusing to wipe." >&2
      exit 1
    fi
    if [ -s "$part/holders" ]; then
      echo "ERROR: partition $pdev has active holders: $(tr '\n' ' ' < "$part/holders"). Refusing to wipe." >&2
      exit 1
    fi
  done
}

# Test that the mount works, then mark done and self-disable.
# Only call this once the fstab entry is in place.
finish_setup() {
  if findmnt --target "$MOUNT_POINT" >/dev/null 2>&1; then
    echo "$MOUNT_POINT is already mounted."
  else
    echo "Test-mounting $MOUNT_POINT..."
    mount "$MOUNT_POINT"
  fi
  echo "Mount test OK: $(findmnt --noheadings --target "$MOUNT_POINT" | tr -s ' ')"

  touch /var/lib/setup-bcache.done
  systemctl disable setup-bcache.service
  echo "=== bcache setup complete ==="
  echo "Device: $BCACHE_DEV"
  echo "Mount: $MOUNT_POINT (mounted now; fstab entry for UUID=$FS_UUID)"
}

echo "=== Setting up bcache ==="
echo "Cache device (NVMe): $CACHE_DEV"
echo "Backing device (HDD): $BACKING_DEV"

# --- Pre-flight: verify required tools ---
for cmd in wipefs make-bcache mkfs.ext4 blkid bcache-super-show findmnt blockdev; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required command '$cmd' not found." >&2
    exit 1
  fi
done

# --- Pre-flight: verify device paths resolve to block devices ---
if [ ! -b "$CACHE_DEV" ]; then
  echo "ERROR: Cache device '$CACHE_DEV' is not a block device (or does not exist)." >&2
  exit 1
fi
if [ ! -b "$BACKING_DEV" ]; then
  echo "ERROR: Backing device '$BACKING_DEV' is not a block device (or does not exist)." >&2
  exit 1
fi

# --- Pre-flight: identity check ---
# Print where the by-id paths resolve and verify the hardware models match
# expectations before touching anything.
CACHE_REAL=$(readlink -f "$CACHE_DEV")
BACKING_REAL=$(readlink -f "$BACKING_DEV")
echo "Cache device resolves to:   $CACHE_REAL"
echo "Backing device resolves to: $BACKING_REAL"

CACHE_MODEL=$(get_device_model "$CACHE_REAL")
BACKING_MODEL=$(get_device_model "$BACKING_REAL")
echo "Cache device model:   ${CACHE_MODEL:-<unreadable>}"
echo "Backing device model: ${BACKING_MODEL:-<unreadable>}"

if [[ "$CACHE_MODEL" != *"$CACHE_EXPECTED_MODEL"* ]]; then
  echo "ERROR: Cache device model '$CACHE_MODEL' does not contain '$CACHE_EXPECTED_MODEL'. Refusing to continue." >&2
  exit 1
fi
if [ -z "$BACKING_MODEL" ]; then
  echo "ERROR: Could not read backing device model ($BACKING_REAL). Refusing to continue." >&2
  exit 1
fi

# --- Pre-flight: sanity-check device sizes to avoid wiping the wrong disk ---
CACHE_SECTORS=$(blockdev --getsz "$CACHE_DEV")
BACKING_SECTORS=$(blockdev --getsz "$BACKING_DEV")
echo "Cache device size: $CACHE_SECTORS sectors"
echo "Backing device size: $BACKING_SECTORS sectors"

if [ "$CACHE_SECTORS" -le 0 ]; then
  echo "ERROR: Cache device reports 0 sectors. Is it the correct device?" >&2
  exit 1
fi
if [ "$BACKING_SECTORS" -le 0 ]; then
  echo "ERROR: Backing device reports 0 sectors. Is it the correct device?" >&2
  exit 1
fi

# --- Pre-flight: verify mount point directory exists ---
if [ ! -d "$MOUNT_POINT" ]; then
  echo "Mount point '$MOUNT_POINT' does not exist. Creating..."
  mkdir -p "$MOUNT_POINT"
fi

# --- Check if devices already have valid bcache superblocks ---
# This protects against re-provisioning (fresh Ignition boot) wiping
# drives that already contain a working bcache with data.
CACHE_HAS_SUPERBLOCK=false
BACKING_HAS_SUPERBLOCK=false
if blkid -p "$CACHE_DEV" 2>/dev/null | grep -q "TYPE=bcache"; then
  CACHE_HAS_SUPERBLOCK=true
fi
if blkid -p "$BACKING_DEV" 2>/dev/null | grep -q "TYPE=bcache"; then
  BACKING_HAS_SUPERBLOCK=true
fi

echo "Cache device has bcache superblock: $CACHE_HAS_SUPERBLOCK"
echo "Backing device has bcache superblock: $BACKING_HAS_SUPERBLOCK"

if [ "$CACHE_HAS_SUPERBLOCK" = true ] && [ "$BACKING_HAS_SUPERBLOCK" = true ]; then
  # Both devices already have bcache — reassemble and verify config.
  echo "Existing bcache detected. Reassembling..."

  # The kernel does not auto-assemble bcache; use the same reassembly logic
  # as bcache-reassemble.service (exits 0 if already assembled).
  /usr/local/bin/bcache-reassemble.sh

  # The device may already exist (assembled at boot); match by size only.
  BCACHE_DEV=$(wait_for_bcache_dev 15)
  echo "Bcache device: $BCACHE_DEV"

  # Verify cache policy
  CURRENT_POLICY=$(cat "/sys/block/$(basename "$BCACHE_DEV")/bcache/cache_policy" 2>/dev/null || echo "")
  if [ "$CURRENT_POLICY" != "$DESIRED_POLICY" ]; then
    echo "Policy mismatch (current=${CURRENT_POLICY:-<none>}, desired=$DESIRED_POLICY). Fixing..."
    echo "$DESIRED_POLICY" > "/sys/block/$(basename "$BCACHE_DEV")/bcache/cache_policy"
  fi

  # Verify fstab entry
  FS_UUID=$(blkid -s UUID -o value "$BCACHE_DEV" 2>/dev/null || echo "")
  if [ -z "$FS_UUID" ]; then
    echo "WARNING: Could not read filesystem UUID from $BCACHE_DEV." >&2
  elif grep -qF "UUID=$FS_UUID" /etc/fstab; then
    echo "Bcache already properly configured. Skipping make-bcache and mkfs."
    echo "Existing data preserved."
  else
    echo "fstab entry missing for UUID=$FS_UUID. Adding..."
    remove_fstab_mountpoint
    echo "UUID=$FS_UUID $MOUNT_POINT ext4 $FSTAB_OPTIONS 0 0" >> /etc/fstab
  fi

  finish_setup
  exit 0
fi

# --- No existing bcache — full setup (wipe + format) ---
echo "No existing bcache found. Performing full setup (wipe + format)."

# --- Guardrail: refuse to wipe devices that are mounted or held ---
verify_device_free "$CACHE_DEV"
verify_device_free "$BACKING_DEV"

# Clean up any stale bcache registrations from previous failed attempts.
# cache_dev/backing_dev are symlinks to the block device's sysfs dir, so
# stop the set via <blockdev sysfs>/bcache/state.
echo "Cleaning up stale bcache registrations..."
for bc_dir in /sys/fs/bcache/*/; do
  for kind in backing_dev cache_dev; do
    [ -e "${bc_dir}${kind}" ] || continue
    echo stopped > "$(readlink -f "${bc_dir}${kind}")/bcache/state" 2>/dev/null || true
  done
done

# Wipe any existing partition tables / signatures
echo "Wiping device signatures on $CACHE_DEV..."
wipefs -a "$CACHE_DEV"
echo "Wiping device signatures on $BACKING_DEV..."
wipefs -a "$BACKING_DEV"

# Register as bcache devices
echo "Creating bcache superblock on cache device..."
make-bcache -C "$CACHE_DEV"

echo "Creating bcache superblock on backing device..."
make-bcache -B "$BACKING_DEV"

# Read the bcache UUIDs directly from the superblocks (not by globbing
# /sys/fs/bcache, where stale entries from a failed attempt could win).
CACHE_UUID=$(bcache-super-show "$CACHE_DEV" 2>/dev/null | grep -m1 '^UUID:' | awk '{print $2}' || true)
BACKING_UUID=$(bcache-super-show "$BACKING_DEV" 2>/dev/null | grep -m1 '^UUID:' | awk '{print $2}' || true)
echo "Cache UUID: $CACHE_UUID"
echo "Backing UUID: $BACKING_UUID"
if [ -z "$CACHE_UUID" ] || [ -z "$BACKING_UUID" ]; then
  echo "ERROR: Could not read bcache UUIDs from superblocks." >&2
  exit 1
fi

# The kernel registers a bcache device when its superblock is read; probe
# the device until the backing's sysfs entry (with its register file)
# appears.
REGISTER_FILE="/sys/fs/bcache/$BACKING_UUID/register"
for _ in $(seq 1 10); do
  [ -f "$REGISTER_FILE" ] && break
  blkid -p "$BACKING_DEV" >/dev/null 2>&1 || true
  sleep 1
done
if [ ! -f "$REGISTER_FILE" ]; then
  echo "ERROR: $REGISTER_FILE did not appear after make-bcache; device registration failed." >&2
  echo "sys/fs/bcache contents:" >&2
  ls -la /sys/fs/bcache/ >&2
  exit 1
fi

# Snapshot existing bcache devices so we can identify the one our attach
# creates (must not pick a stale device from another set).
PRE_ATTACH_BCACHE=$(ls /dev/bcache* 2>/dev/null | tr '\n' ' ' || true)

# Attach cache to backing device: write the cache's uuid to the backing's
# register file (the standard attach/reassembly procedure).
echo "Registering cache with backing device..."
echo "$CACHE_UUID" > "$REGISTER_FILE"

# Wait for the combined bcache device to appear
echo "Waiting for bcache device to appear..."
BCACHE_DEV=$(wait_for_bcache_dev 15 "$PRE_ATTACH_BCACHE")
echo "Bcache device: $BCACHE_DEV"

# Guardrail: bcache must present the backing's capacity; a mismatch means
# we would format the wrong device.
if [ "$(blockdev --getsz "$BCACHE_DEV")" -ne "$BACKING_SECTORS" ]; then
  echo "ERROR: $BCACHE_DEV is $(blockdev --getsz "$BCACHE_DEV") sectors, expected $BACKING_SECTORS. Refusing to format." >&2
  exit 1
fi

# Set cache policy (writes bypass cache, reads are cached)
echo "Setting cache policy to $DESIRED_POLICY..."
echo "$DESIRED_POLICY" > "/sys/block/$(basename "$BCACHE_DEV")/bcache/cache_policy"

# Verify policy was set
ACTUAL_POLICY=$(cat "/sys/block/$(basename "$BCACHE_DEV")/bcache/cache_policy")
if [ "$ACTUAL_POLICY" != "$DESIRED_POLICY" ]; then
  echo "WARNING: Cache policy is '$ACTUAL_POLICY', expected '$DESIRED_POLICY'." >&2
fi

# Format with ext4
echo "Formatting $BCACHE_DEV with ext4..."
mkfs.ext4 -F "$BCACHE_DEV"

# Get filesystem UUID for fstab
FS_UUID=$(blkid -s UUID -o value "$BCACHE_DEV")
echo "Filesystem UUID: $FS_UUID"

# Add to fstab (idempotent — drop any stale entry for the mount point first)
remove_fstab_mountpoint
echo "UUID=$FS_UUID $MOUNT_POINT ext4 $FSTAB_OPTIONS 0 0" >> /etc/fstab

# Verify fstab entry
if ! grep -qF "UUID=$FS_UUID" /etc/fstab; then
  echo "ERROR: fstab entry was not written successfully." >&2
  exit 1
fi

finish_setup
