#!/bin/bash
#
# nevua-ketana storage: 20 TB HDD cached by the 1 TB NVMe, via LVM cache.
#
#   BACKING_DEV  Toshiba 20 TB HDD     -> PV holding lv_data  (the data LV)
#   CACHE_DEV    Crucial P5 Plus 1 TB  -> PV holding lv_cache (the cache pool)
#   /dev/vg_storage/lv_data  XFS, writethrough-cached  <- the filesystem to mount
#   (the pool and the origin get internal sub-LVs — lv_cache_cpool{,_cdata,_cmeta}
#    and lv_data_corig; they are managed by LVM, never touch them by hand)
#
# Contract: the two data disks must already be blank when this runs (Ignition's
# wipe_table/wipefs does that during provisioning). If they are not blank it stops
# with an error — there is deliberately no mode that destroys existing data here,
# that is what ./teardown_storage.sh is for.
#
# Written for ONE machine, so nothing is probed at runtime: every size below is a
# hardcoded measurement with a note on where it came from. If a disk is ever
# swapped, re-measure the two values marked (*). Device identifiers: HARDWARE.md.
#
# Measured on nevua-ketana, 2026-08-29:
#   HDD   20,000,588,955,648 B = 18.19 TiB, 512 logical / 4096 physical (512e) (*)
#   NVMe   1,000,204,886,016 B = 931.51 GiB, 512 logical / 512 physical  (*)
#
#   CACHE_SIZE=900G — the NVMe PV is 931.51 GiB, so 900G leaves ~31 GiB for the
#     pool's metadata LV (measured: 44 MiB), its metadata spare and LVM headroom.
#
#   CHUNK_SIZE=1024 — dm-cache maps the pool in power-of-two chunks and LVM caps
#     a pool at CACHE_MAX_CHUNKS of them, so the minimum chunk grows with the
#     pool: ceil(900 GiB / 1,000,000) = 960 KiB, rounded up to a power of two is
#     1 MiB (921,600 chunks). The old hardcoded 512K failed outright:
#       "Chunk size 512.00 KiB is less than required minimal chunk size
#        960.00 KiB for a cache pool of 900.00 GiB size and limit 1000000 chunks"
#     1 MiB is also a multiple of the HDD's 4096-byte physical sectors. CACHE_MAX_CHUNKS
#     is pinned on the lvcreate command line so this stays true whatever the
#     distro default is.
#
#   MIXED_BS_CFG — the HDD's 4096-byte *physical* sectors vs the NVMe's 512 make
#     pvcreate/vgcreate warn "WARNING: Devices have inconsistent physical block
#     sizes (4096 and 512)". An LVM cache needs pool and origin in one VG, so
#     the mismatch is inherent and harmless (LVM aligns everything to the larger
#     size); the config silences just that warning. A mismatch of the *logical*
#     block sizes is the one that would matter, and LVM refuses that on its own.
#     Re-check after a disk swap with:  lsblk -dno NAME,LOG-SEC,PHY-SEC /dev/sdX
#

set -eo pipefail

CACHE_DEV="/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C"    # Crucial P5 Plus 1 TB
BACKING_DEV="/dev/disk/by-id/wwn-0x5000039e58d0650e"            # Toshiba 20 TB HDD
# The 512 GB white-label NVMe that boots CoreOS. Never let it be a target.
OS_DEV="/dev/disk/by-id/nvme-PCIe_SSD_20090851200275"

VG_NAME="vg_storage"
DATA_LV="lv_data"
CACHE_LV="lv_cache"
DATA_DEV="/dev/mapper/${VG_NAME}-${DATA_LV}"
CACHE_SIZE="900G"
CACHE_MODE="writethrough"      # lvm2: writethrough | writeback | passthrough (no writearound)
CHUNK_SIZE="1024"              # KiB — see the derivation in the header
CACHE_MAX_CHUNKS=1000000       # allocation/cache_pool_max_chunks, pinned on lvcreate
MIXED_BS_CFG='devices { allow_mixed_block_sizes = 1 }'

[ "$EUID" -eq 0 ] || { echo "Please run as root (sudo)." >&2; exit 1; }

echo "Checking devices..."
for d in "$CACHE_DEV" "$BACKING_DEV"; do
  [ "$d" != "$OS_DEV" ] || { echo "Error: $d is the OS disk." >&2; exit 1; }
  [ -b "$d" ] || { echo "Error: $d not found (check the by-id paths in HARDWARE.md)." >&2; exit 1; }

  # The disks must arrive blank: Ignition's wipe_table/wipefs does that on a
  # provisioning run. lsblk prints the disk *and its children*, so one probe
  # catches a filesystem, an LVM label, a RAID/bcache member, a partition table
  # and anything mounted anywhere on the disk. Anything found here means this
  # script is not the tool for the job — bail out rather than guess.
  if lsblk -rno FSTYPE,PTTYPE,MOUNTPOINTS "$d" | grep -q '[^[:space:]]'; then
    echo "Error: $d is not blank:" >&2
    lsblk -o NAME,FSTYPE,PTTYPE,MOUNTPOINTS "$d" >&2
    echo "       Run ./teardown_storage.sh to wipe it, or re-provision with Ignition." >&2
    exit 1
  fi
done

# Load the cache target explicitly. LVM would autoload it, but failing here says
# "the module was trimmed out of this image" instead of failing mid-rebuild.
modprobe dm_cache

# 1. Physical volumes (replaces the device initialisation inside make-bcache).
#    No wipefs here: Ignition erases the partition tables of both disks
#    (storage.disks wipe_table) before this runs, and pvcreate -y clears any
#    leftover signature it dislikes (e.g. an old bcache superblock). The pre-flight
#    above is what guarantees the disks really are blank; rebuilding by hand means
#    running ./teardown_storage.sh first.
echo "Creating physical volumes..."
lvm pvcreate -y --config "$MIXED_BS_CFG" "$BACKING_DEV" "$CACHE_DEV"

# 2. Volume group (LVM-only requirement: cache pool and origin must share a VG).
echo "Creating volume group $VG_NAME..."
lvm vgcreate --config "$MIXED_BS_CFG" "$VG_NAME" "$BACKING_DEV" "$CACHE_DEV"

# 3. Origin LV — all remaining space on the HDD PV (replaces make-bcache -B).
echo "Creating $VG_NAME/$DATA_LV (~18.19 TiB) on the backing HDD..."
lvm lvcreate -n "$DATA_LV" -l 100%FREE "$VG_NAME" "$BACKING_DEV"

# 4. Cache pool LV on the NVMe (replaces make-bcache -C).
echo "Creating $VG_NAME/$CACHE_LV (${CACHE_SIZE}, chunk ${CHUNK_SIZE}K) on the cache SSD..."
lvm lvcreate -n "$CACHE_LV" -L "$CACHE_SIZE" --type cache-pool \
    --cachemode "$CACHE_MODE" \
    --chunksize "$CHUNK_SIZE" \
    --config "allocation { cache_pool_max_chunks = $CACHE_MAX_CHUNKS }" \
    "$VG_NAME" "$CACHE_DEV"

# 5. Attach the pool to the origin (replaces the cache-set linking done by
#    `make-bcache -C ... -B ...`). --zero y is required for unattended runs: LVM
#    asks "Do you want to wipe existing metadata of cache pool ...? [n]" if the
#    pool's metadata area is not known-empty (stale bytes past wipe_table's
#    reach count), and with no stdin that prompt aborts the conversion.
#    The cache mode can also be changed later with `lvchange --cachemode`,
#    persistently.
echo "Caching $DATA_LV with $CACHE_LV (mode: $CACHE_MODE)..."
lvm lvconvert --type cache --cachepool "$VG_NAME/$CACHE_LV" \
    --cachemode "$CACHE_MODE" --zero y \
    "$VG_NAME/$DATA_LV"

# 6. Give udev a moment to create the mapped device before formatting it.
udevadm settle
for _ in {1..10}; do
    [ -e "$DATA_DEV" ] && break
    sleep 1
done
if [ ! -e "$DATA_DEV" ]; then
    echo "Error: $DATA_DEV was not activated." >&2
    lvm lvs -a "$VG_NAME" >&2 || true
    exit 1
fi

# 7. Format the cached LV with XFS.
echo "Formatting $DATA_DEV with XFS..."
mkfs.xfs -f "$DATA_DEV"

echo "Success! /dev/$VG_NAME/$DATA_LV is a ${CACHE_MODE}-cached XFS volume."
lvm lvs -a -o+cache_mode,chunk_size "$VG_NAME"

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
