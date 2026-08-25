#!/bin/bash
set -euo pipefail

# Stable device IDs (from /dev/disk/by-id/)
BDEV=/dev/disk/by-id/wwn-0x5000039e58d0650e       # 20TB TOSHIBA HDWR62AU HDD (backing)
CDEV=/dev/disk/by-id/nvme-eui.00a07501e9cabc5c     # 1TB CT1000P510SSD8 NVMe (cache)
MOUNTPOINT=/var/mnt/cached-storage
FS_UUID=7c1e6a42-9f3d-4b8e-a51c-2d0b8e4f6a37

[ -b "$BDEV" ] || { echo "ERROR: backing device $BDEV not found" >&2; exit 1; }
[ -b "$CDEV" ] || { echo "ERROR: cache device $CDEV not found" >&2; exit 1; }

# Resolve kernel names (unstable, but fine at runtime) for sysfs queries
bname=$(basename "$(readlink -f "$BDEV")")
cname=$(basename "$(readlink -f "$CDEV")")

# Sanity checks on sizes (512-byte sector counts) so we never
# wipe the wrong device.
bsectors=$(cat "/sys/block/$bname/size")
csectors=$(cat "/sys/block/$cname/size")
if (( bsectors < 30000000000 || bsectors > 60000000000 )); then
  echo "ERROR: unexpected backing device size: $bsectors sectors" >&2; exit 1
fi
if (( csectors < 1800000000 || csectors > 2100000000 )); then
  echo "ERROR: unexpected cache device size: $csectors sectors" >&2; exit 1
fi
echo "Backed device $bname: $bsectors sectors; cache device $cname: $csectors sectors"

# --- Deregister any pre-existing bcache devices (leftovers) ---
for d in /dev/bcache*; do
  if [ -e "$d" ]; then rm -f "$d"; fi
done

# --- Wipe both devices ---
# Zero the first 4GiB of each (destroys partition tables and all
# superblocks) and clear any remaining signatures. A full-disk
# zero of the 20TB drive takes ~a day and is not needed here, since
# the data is being replaced by the new bcache layout.
echo "Wiping backing device..."
dd if=/dev/zero of="$BDEV" bs=1M count=4096 conv=fsync status=progress
wipefs -a "$BDEV"
echo "Wiping cache device..."
dd if=/dev/zero of="$CDEV" bs=1M count=4096 conv=fsync status=progress
wipefs -a "$CDEV"
sync

# --- Create bcache devices ---
modprobe bcache 2>/dev/null || true
echo "Creating bcache backing device..."
bcache-make -B "$BDEV"
# -b writearound: reads are served from the NVMe cache; writes go
# only to the HDD and are NOT written to the cache.
echo "Creating bcache cache device (writearound)..."
bcache-make -C -b writearound "$CDEV"

# --- Wait for the kernel to attach the cache set to the backing
#     device (automatic once both are registered) ---
echo "Waiting for cache set to attach..."
for i in $(seq 1 120); do
  state=$(cat "/sys/block/$bname/bcache/state" 2>/dev/null || echo "missing")
  if [ -n "$state" ] && [ "$state" != "no cache" ]; then
    echo "Cache attached (state: $state)"
    break
  fi
  sleep 5
done
if [ "$state" = "no cache" ] || [ "$state" = "missing" ]; then
  echo "ERROR: cache set did not attach" >&2; exit 1
fi

# --- Filesystem on the bcache device ---
BCACHE_DEV=$(ls -d /dev/bcache* | head -n1)
echo "Creating xfs on $BCACHE_DEV..."
mkfs.xfs -f -m uuid="${FS_UUID}" "$BCACHE_DEV"

# --- Mountpoint + fstab entry ---
mkdir -p "$MOUNTPOINT"
if ! grep -q " $MOUNTPOINT " /etc/fstab; then
  echo "UUID=${FS_UUID} ${MOUNTPOINT} xfs defaults,nofail 0 0" >> /etc/fstab
fi
mount "$MOUNTPOINT" || echo "WARNING: initial mount failed" >&2
echo "bcache setup complete: ${BCACHE_DEV} (UUID ${FS_UUID}) mounted at ${MOUNTPOINT}"
