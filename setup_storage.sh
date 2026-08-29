#!/bin/bash
#
# nevua-ketana storage: 20 TB HDD read cache with the 1 TB NVMe, via LVM cache.
#
# Devices (see HARDWARE.md for the by-id paths)
#   BACKING_DEV  Toshiba 20 TB HDD   -> LVM PV holding the data LV
#   CACHE_DEV    Crucial P5 Plus 1TB -> LVM PV holding the cache pool
#
# Resulting layout
#   vg_storage/lv_data   ~20 TB, linear on the HDD, cached by lv_cache
#   vg_storage/lv_cache  CACHE_SIZE cache-pool on the NVMe
#   -> /dev/vg_storage/lv_data  (XFS) is the filesystem to mount
#   (lvconvert also creates internal LVs lv_data_cvol / lv_data_corig — leave them alone)
#

set -eo pipefail

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

# Define your cache (SSD) and backing (HDD) devices
CACHE_DEV="/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C"
BACKING_DEV="/dev/disk/by-id/wwn-0x5000039e58d0650e"

VG_NAME="vg_storage"
DATA_LV="lv_data"
CACHE_LV="lv_cache"
CACHE_SIZE="900G"            # keep ~100 GiB of the NVMe free for pool metadata + headroom
CACHE_MODE="writethrough"    # lvm2: writethrough | writeback | passthrough (no writearound)
CHUNK_SIZE="512"             # KiB; 900G / 512K chunks ~= 56 MiB of cache metadata

# Mount point created by the Ignition config (/var/mnt/storage). Not mounted by
# this script — see the note at the bottom of the file.
TARGET_DIR="/var/mnt/storage"

echo "Checking prerequisites..."
command -v lvm >/dev/null || {
  echo "Error: lvm2 is not installed. exiting!" >&2
  exit 1
}
for d in "$CACHE_DEV" "$BACKING_DEV"; do
  [ -b "$d" ] || { echo "Error: $d not found (check the by-id paths in HARDWARE.md)." >&2; exit 1; }
  # lsblk also lists the device's children, so this catches an active bcache0/md/LV on top.
  if lsblk -rno MOUNTPOINTS "$d" | grep -q '[^[:space:]]'; then
    echo "Error: $d (or something on top of it) is mounted. Unmount it first." >&2
    exit 1
  fi
done

# 0. Load the cache target. LVM/libdevmapper autoloads this on demand; the
#    explicit modprobe mirrors the old `modprobe bcache` and fails loudly if
#    the module was trimmed out of the image.
echo "Loading dm-cache kernel module..."
modprobe dm_cache

# 1. Idempotency guard: refuse to rebuild an existing VG unless asked to.
if lvm vgdisplay "$VG_NAME" >/dev/null 2>&1; then
  if [ "${FORCE:-0}" != "1" ]; then
    echo "Error: VG $VG_NAME already exists. Re-run with FORCE=1 to destroy and rebuild it." >&2
    exit 1
  fi
  echo "FORCE=1: removing existing VG $VG_NAME..."
  lvm lvchange -an "$VG_NAME" 2>/dev/null || true
  lvm vgremove -f -y "$VG_NAME"
fi

# 2. Physical volumes (replaces the device initialisation inside make-bcache).
#    No wipefs here: Ignition erases the partition tables of both disks
#    (storage.disks wipe_table) before this runs, and pvcreate -y clears any
#    leftover signature it dislikes (e.g. the old bcache superblock). If you
#    re-run this script by hand later, wipe the disks yourself first.
echo "Creating physical volumes..."
lvm pvcreate -y "$BACKING_DEV" "$CACHE_DEV"

# 3. Volume group (LVM-only requirement: cache pool and origin must share a VG).
echo "Creating volume group $VG_NAME..."
lvm vgcreate "$VG_NAME" "$BACKING_DEV" "$CACHE_DEV"

# 4. Origin LV — all remaining space on the HDD PV (replaces make-bcache -B).
echo "Creating $VG_NAME/$DATA_LV on the backing HDD..."
lvm lvcreate -n "$DATA_LV" -l 100%FREE "$VG_NAME" "$BACKING_DEV"

# 5. Cache pool LV on the NVMe (replaces make-bcache -C).
echo "Creating $VG_NAME/$CACHE_LV (${CACHE_SIZE}, chunk ${CHUNK_SIZE}K) on the cache SSD..."
lvm lvcreate -n "$CACHE_LV" -L "$CACHE_SIZE" --type cache-pool \
    --cachemode "$CACHE_MODE" \
    --poolmetadataspare n \
    --chunksize "$CHUNK_SIZE" \
    "$VG_NAME" "$CACHE_DEV"

# 6. Attach the pool to the origin (replaces the cache-set linking done by
#    `make-bcache -C ... -B ...`). The cache mode could also be set afterwards
#    with `lvchange --cachemode`, and that change is persistent.
echo "Caching $DATA_LV with $CACHE_LV (mode: $CACHE_MODE)..."
lvm lvconvert --type cache --cachepool "$VG_NAME/$CACHE_LV" \
    --cachemode "$CACHE_MODE" \
    "$VG_NAME/$DATA_LV"

# 7. Force udev to process the new mapped device, then wait for the node.
echo "Waiting for /dev/mapper/${VG_NAME}-${DATA_LV} to settle..."
udevadm settle
for i in {1..10}; do
    [ -e "/dev/mapper/${VG_NAME}-${DATA_LV}" ] && break
    sleep 1
done
if [ ! -e "/dev/mapper/${VG_NAME}-${DATA_LV}" ]; then
    echo "Error: /dev/mapper/${VG_NAME}-${DATA_LV} was not activated." >&2
    lvm lvs -a "$VG_NAME" >&2 || true
    exit 1
fi

# 8. Format the cached LV with XFS.
echo "Formatting /dev/$VG_NAME/$DATA_LV with XFS..."
mkfs.xfs -f "/dev/mapper/${VG_NAME}-${DATA_LV}"

echo "Success! /dev/$VG_NAME/$DATA_LV is a ${CACHE_MODE}-cached XFS volume."
lvm lvs -a "$VG_NAME"

# Nothing else is required for persistence: lvm2 activates vg_storage (and
# therefore the cache) at every boot, and the cache mode is stored in the LVM
# metadata. Verify after a reboot with:  lvs -o lv_name,cache_mode,cache_size
#
# Mounting is out of scope here (it was in the bcache version too). On CoreOS
# prefer a systemd mount unit over /etc/fstab, e.g.
#   /etc/systemd/system/var-mnt-storage.mount
# with What=/dev/vg_storage/lv_data, Type=xfs, and options like
#   noatime,nofail,x-systemd.device-timeout=30s
# so a missing SSD/cache can never block boot.
#
# Cache lifecycle:
#   lvm lvchange --cachemode writeback vg_storage/lv_data   # switch mode (unmounted)
#   lvm lvconvert --type cache --uncache vg_storage/lv_data # detach cache cleanly
#   If the NVMe dies: vgreduce --removemissing --force $VG_NAME, then mount.
