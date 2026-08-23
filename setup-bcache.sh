#!/bin/bash
set -euo pipefail

CACHE_DEV="/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C"
BACKING_DEV="/dev/disk/by-id/wwn-0x5000039e58d0650e"
DESIRED_POLICY="writearound"

echo "=== Setting up bcache ==="
echo "Cache device (NVMe): $CACHE_DEV"
echo "Backing device (HDD): $BACKING_DEV"

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
  partprobe "$CACHE_DEV" 2>/dev/null || true
  partprobe "$BACKING_DEV" 2>/dev/null || true
  udevadm settle

  # Wait for bcache device to appear (may already be assembled by kernel)
  BCACHE_DEV=""
  for i in $(seq 1 10); do
    BCACHE_DEV=$(ls /dev/bcache* 2>/dev/null | head -1 || true)
    if [ -n "$BCACHE_DEV" ]; then
      break
    fi
    sleep 1
  done

  if [ -z "$BCACHE_DEV" ]; then
    echo "ERROR: bcache superblocks exist but no /dev/bcache* device appeared."
    echo "Manual intervention required. Aborting."
    exit 1
  fi

  # Verify cache policy
  CURRENT_POLICY=$(cat /sys/block/$(basename "$BCACHE_DEV")/bcache/cache_policy 2>/dev/null || echo "")
  if [ "$CURRENT_POLICY" != "$DESIRED_POLICY" ]; then
    echo "Policy mismatch (current=$CURRENT_POLICY, desired=$DESIRED_POLICY). Fixing..."
    echo "$DESIRED_POLICY" > /sys/block/$(basename "$BCACHE_DEV")/bcache/cache_policy
  fi

  # Verify fstab entry
  FS_UUID=$(blkid -s UUID -o value "$BCACHE_DEV" 2>/dev/null || echo "")
  if [ -n "$FS_UUID" ] && grep -q "$FS_UUID" /etc/fstab 2>/dev/null; then
    echo "Bcache already properly configured. Skipping make-bcache and mkfs."
    echo "Existing data preserved."
  else
    echo "fstab entry missing. Adding..."
    echo "$FS_UUID /var/mnt/cached-storage ext4 defaults,noatime 0 0" >> /etc/fstab
  fi

  touch /var/lib/setup-bcache.done
  systemctl disable setup-bcache.service
  exit 0
fi

# --- No existing bcache — full setup (wipe + format) ---
echo "No existing bcache found. Performing full setup (wipe + format)."

# Wipe any existing partition tables / signatures
wipefs -a "$CACHE_DEV"
wipefs -a "$BACKING_DEV"

# Register as bcache devices
make-bcache -C "$CACHE_DEV"
make-bcache -B "$BACKING_DEV"

# Get the bcache UUIDs
CACHE_UUID=$(cat /sys/block/bcache*/bcache/cache_uuid 2>/dev/null || echo "")
BACKING_UUID=$(cat /sys/block/bcache*/bcache/backing_uuid 2>/dev/null || echo "")

# Attach cache to backing device
for bc in /sys/fs/bcache/*/; do
  if [ -f "${bc}backing_dev" ]; then
    echo "Attaching cache to backing device..."
    echo "$CACHE_UUID" > "${bc}backing_dev"
    break
  fi
done

# Set writearound policy (writes bypass cache, reads are cached)
echo "writearound" > /sys/block/bcache*/bcache/cache_policy

# Wait for bcache device to appear
sleep 5
BCACHE_DEV=$(ls /dev/bcache* 2>/dev/null | head -1)
echo "Bcache device: $BCACHE_DEV"

# Format with ext4
mkfs.ext4 -F "$BCACHE_DEV"

# Get filesystem UUID for fstab
FS_UUID=$(blkid -s UUID -o value "$BCACHE_DEV")
echo "Filesystem UUID: $FS_UUID"

# Add to fstab (idempotent)
if ! grep -q "$FS_UUID" /etc/fstab; then
  echo "$FS_UUID /var/mnt/cached-storage ext4 defaults,noatime 0 0" >> /etc/fstab
fi

echo "=== bcache setup complete ==="
touch /var/lib/setup-bcache.done
systemctl disable setup-bcache.service
