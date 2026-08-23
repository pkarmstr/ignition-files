#!/bin/bash
set -euo pipefail

CACHE_DEV="/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C"
BACKING_DEV="/dev/disk/by-id/wwn-0x5000039e58d0650e"
DESIRED_POLICY="writearound"
MOUNT_POINT="/var/mnt/cached-storage"

# --- Helper: wait for a bcache device to appear ---
wait_for_bcache_dev() {
  local timeout="${1:-15}"
  local start=$SECONDS
  while [ $(( SECONDS - start )) -lt "$timeout" ]; do
    local dev
    dev=$(ls /dev/bcache* 2>/dev/null | head -1 || true)
    if [ -n "$dev" ] && [ -b "$dev" ]; then
      echo "$dev"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Timed out waiting for /dev/bcache* device (${timeout}s)." >&2
  return 1
}

# --- Helper: find the sysfs path for a specific bcache UUID ---
find_bcache_sysfs() {
  local target_uuid="$1"
  local entry
  for entry in /sys/fs/bcache/*/; do
    local this_uuid
    this_uuid=$(cat "${entry}uuid" 2>/dev/null || true)
    if [ "$this_uuid" = "$target_uuid" ]; then
      echo "$entry"
      return 0
    fi
  done
  return 1
}

echo "=== Setting up bcache ==="
echo "Cache device (NVMe): $CACHE_DEV"
echo "Backing device (HDD): $BACKING_DEV"

# --- Pre-flight: verify required tools ---
for cmd in wipefs make-bcache mkfs.ext4 blkid; do
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

# --- Pre-flight: sanity-check device sizes to avoid wiping the wrong disk ---
CACHE_SECTORS=$(blockdev --getsz "$CACHE_DEV" 2>/dev/null || echo "0")
BACKING_SECTORS=$(blockdev --getsz "$BACKING_DEV" 2>/dev/null || echo "0")
echo "Cache device size: $CACHE_SECTORS sectors"
echo "Backing device size: $BACKING_SECTORS sectors"

if [ "$CACHE_SECTORS" -eq 0 ]; then
  echo "ERROR: Cache device reports 0 sectors. Is it the correct device?" >&2
  exit 1
fi
if [ "$BACKING_SECTORS" -eq 0 ]; then
  echo "ERROR: Backing device reports 0 sectors. Is it the correct device?" >&2
  exit 1
fi

# --- Pre-flight: verify mount point directory exists ---
if [ ! -d "$MOUNT_POINT" ]; then
  echo "WARNING: Mount point '$MOUNT_POINT' does not exist. Creating..." >&2
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

  # Trigger udev to register existing bcache devices
  # (partprobe is for partition tables; udevadm trigger is correct for bcache)
  udevadm trigger 2>/dev/null || true
  udevadm settle

  # Wait for bcache device to appear (may already be assembled by kernel)
  BCACHE_DEV=$(wait_for_bcache_dev 15)

  # Verify cache policy
  CURRENT_POLICY=$(cat /sys/block/$(basename "$BCACHE_DEV")/bcache/cache_policy 2>/dev/null || echo "")
  if [ "$CURRENT_POLICY" != "$DESIRED_POLICY" ]; then
    echo "Policy mismatch (current=$CURRENT_POLICY, desired=$DESIRED_POLICY). Fixing..."
    echo "$DESIRED_POLICY" > /sys/block/$(basename "$BCACHE_DEV")/bcache/cache_policy
  fi

  # Verify fstab entry (dedup by both UUID and mount point)
  FS_UUID=$(blkid -s UUID -o value "$BCACHE_DEV" 2>/dev/null || echo "")
  if [ -n "$FS_UUID" ] && grep -q "$FS_UUID" /etc/fstab 2>/dev/null; then
    echo "Bcache already properly configured. Skipping make-bcache and mkfs."
    echo "Existing data preserved."
  elif [ -n "$FS_UUID" ]; then
    # UUID not in fstab — check if mount point has a stale entry
    if grep -q "$MOUNT_POINT" /etc/fstab 2>/dev/null; then
      echo "Stale fstab entry for mount point found. Removing..."
      sed -i "/${MOUNT_POINT}/d" /etc/fstab
    fi
    echo "Adding fstab entry..."
    echo "UUID=$FS_UUID $MOUNT_POINT ext4 defaults,noatime 0 0" >> /etc/fstab
  else
    echo "WARNING: Could not read filesystem UUID from $BCACHE_DEV." >&2
  fi

  touch /var/lib/setup-bcache.done
  systemctl disable setup-bcache.service
  exit 0
fi

# --- No existing bcache — full setup (wipe + format) ---
echo "No existing bcache found. Performing full setup (wipe + format)."

# Clean up any stale bcache devices from previous failed attempts
echo "Cleaning up stale bcache registrations..."
for bc_dir in /sys/fs/bcache/*/; do
  bc_uuid=$(cat "${bc_dir}uuid" 2>/dev/null || true)
  # Try to detach cache
  if [ -f "${bc_dir}cache_dev" ]; then
    echo "" > "${bc_dir}cache_dev" 2>/dev/null || true
  fi
  # Try to stop backing device
  if [ -f "${bc_dir}backing_dev" ]; then
    echo "stopped" > "${bc_dir}registration" 2>/dev/null || true
    echo "" > "${bc_dir}backing_dev" 2>/dev/null || true
  fi
done
udevadm settle

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

# Allow udev to process the new superblocks
udevadm settle

# Get the bcache UUIDs from sysfs (match by device, not glob)
CACHE_UUID=""
BACKING_UUID=""
for bc_dir in /sys/fs/bcache/*/; do
  bc_uuid=$(cat "${bc_dir}uuid" 2>/dev/null || true)
  # Determine if this is cache or backing by checking sysfs attributes
  if [ -f "${bc_dir}cache_dev" ] && [ ! -f "${bc_dir}backing_dev" ]; then
    # This is a cache-only entry
    CACHE_UUID="$bc_uuid"
  elif [ -f "${bc_dir}backing_dev" ] && [ ! -f "${bc_dir}cache_dev" ]; then
    # This is a backing-only entry
    BACKING_UUID="$bc_uuid"
  fi
done

echo "Cache UUID: $CACHE_UUID"
echo "Backing UUID: $BACKING_UUID"

if [ -z "$CACHE_UUID" ] || [ -z "$BACKING_UUID" ]; then
  echo "ERROR: Could not find bcache UUIDs in sysfs. Device registration may have failed." >&2
  echo "sys/fs/bcache contents:" >&2
  ls -la /sys/fs/bcache/ >&2
  exit 1
fi

# Attach cache to backing device (target the specific backing device)
BACKING_SYSFS=$(find_bcache_sysfs "$BACKING_UUID")
if [ -n "$BACKING_SYSFS" ] && [ -f "${BACKING_SYSFS}register" ]; then
  echo "Registering backing device via sysfs..."
  echo "$CACHE_UUID" > "${BACKING_SYSFS}register"
elif [ -n "$BACKING_SYSFS" ] && [ -f "${BACKING_SYSFS}backing_dev" ]; then
  echo "Attaching cache to backing device..."
  echo "$CACHE_UUID" > "${BACKING_SYSFS}backing_dev"
else
  echo "ERROR: Could not find writeable sysfs entry for backing device." >&2
  exit 1
fi

# Wait for the combined bcache device to appear
echo "Waiting for bcache device to appear..."
BCACHE_DEV=$(wait_for_bcache_dev 15)

# Set writearound policy (writes bypass cache, reads are cached)
echo "Setting cache policy to writearound..."
echo "writearound" > /sys/block/$(basename "$BCACHE_DEV")/bcache/cache_policy

# Verify policy was set
ACTUAL_POLICY=$(cat /sys/block/$(basename "$BCACHE_DEV")/bcache/cache_policy)
if [ "$ACTUAL_POLICY" != "writearound" ]; then
  echo "WARNING: Cache policy is '$ACTUAL_POLICY', expected 'writearound'." >&2
fi

# Format with ext4
echo "Formatting $BCACHE_DEV with ext4..."
mkfs.ext4 -F "$BCACHE_DEV"

# Get filesystem UUID for fstab
FS_UUID=$(blkid -s UUID -o value "$BCACHE_DEV")
echo "Filesystem UUID: $FS_UUID"

# Add to fstab (idempotent — dedup by both UUID and mount point)
if grep -q "$MOUNT_POINT" /etc/fstab 2>/dev/null; then
  echo "Removing stale fstab entry for mount point..."
  sed -i "/${MOUNT_POINT}/d" /etc/fstab
fi
if ! grep -q "$FS_UUID" /etc/fstab; then
  echo "UUID=$FS_UUID $MOUNT_POINT ext4 defaults,noatime 0 0" >> /etc/fstab
fi

# Verify fstab entry
if ! grep -q "$FS_UUID" /etc/fstab; then
  echo "ERROR: fstab entry was not written successfully." >&2
  exit 1
fi

echo "=== bcache setup complete ==="
echo "Device: $BCACHE_DEV"
echo "Mount: $MOUNT_POINT (will mount on next boot or manual mount)"
echo "fstab entry added for UUID=$FS_UUID"

touch /var/lib/setup-bcache.done
systemctl disable setup-bcache.service
