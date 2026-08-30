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
# The two LVM warnings the first run of this script produced are both handled:
#   1. "WARNING: Devices have inconsistent physical block sizes (4096 and 512)"
#      Emitted by vgcreate (tools/toollib.c) because the 20 TB HDD reports a
#      4096-byte *physical* block size while the NVMe reports 512. The logical
#      block size of both is 512 (a *logical* mismatch is a hard error, and
#      that is the case that would actually matter). An LVM cache needs pool
#      and origin in the same VG, so the mismatch is inherent; LVM just aligns
#      everything to the larger size. See the block-size pre-flight below:
#      the script verifies the logical sizes itself and silences only the
#      physical mismatch with devices/allow_mixed_block_sizes.
#   2. "Chunk size 512.00 KiB is less than required minimal chunk size
#      960.00 KiB ..." (fatal). LVM caps a pool at
#      allocation/cache_pool_max_chunks (1000000), so a 900G pool needs
#      >= 960K chunks and 512K is rejected. The chunk size is now derived from
#      CACHE_SIZE instead of hardcoded (see the chunk-size pre-flight below).
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
# The NVMe is 1,000 GB = 931.5 GiB of real LVM space, so 900G leaves ~31 GiB
# free for the pool metadata LV plus headroom.
CACHE_SIZE="900G"
CACHE_MODE="writethrough"    # lvm2: writethrough | writeback | passthrough (no writearound)

# allocation/cache_pool_max_chunks — recommended ceiling for cache target v1.9.
# It is pinned on the lvcreate command line so the chunk-size calculation below
# is guaranteed to match what lvcreate enforces.
CACHE_MAX_CHUNKS=1000000

# Cache chunk size in KiB; "" means "compute it". Any value set here is only a
# preference: it is rounded up to a power of two and never accepted below the
# minimum implied by CACHE_SIZE / CACHE_MAX_CHUNKS (for 900G: 1024).
CHUNK_SIZE=""

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

# 0a. Block sizes. LVM puts PVs with different *logical* block sizes in one VG
#     only if told to (otherwise hard error); a mismatch of the *physical* block
#     sizes alone just produces the "inconsistent physical block sizes" warning.
#     Our pair is exactly the warning case: Toshiba 20 TB = 4096 physical /
#     512 logical (512e), Crucial NVMe = 512/512. Check the part that matters
#     ourselves, then silence the warning with devices/allow_mixed_block_sizes
#     on the two commands that inspect both disks.
echo "Checking device block sizes..."
MIXED_BS_CFG='devices { allow_mixed_block_sizes = 1 }'

block_size() {   # <dev> <logical|physical>
    local q
    q="/sys/class/block/$(basename "$(readlink -f "$1")")/queue"
    cat "$q/${2}_block_size" 2>/dev/null || true
}

lbs=( "$(block_size "$BACKING_DEV" logical)" "$(block_size "$CACHE_DEV" logical)" )
pbs=( "$(block_size "$BACKING_DEV" physical)" "$(block_size "$CACHE_DEV" physical)" )

if [ -z "${lbs[0]}" ] || [ -z "${lbs[1]}" ]; then
    echo "  Warning: could not read block sizes from sysfs, skipping the check." >&2
elif [ "${lbs[0]}" != "${lbs[1]}" ]; then
    echo "Error: logical block sizes differ (${lbs[0]} vs ${lbs[1]} bytes) between" >&2
    echo "       $BACKING_DEV and $CACHE_DEV." >&2
    echo "       LVM cannot mix those in one VG, so an LVM cache is not possible" >&2
    echo "       on this disk pair." >&2
    exit 1
elif [ "${pbs[0]}" != "${pbs[1]}" ]; then
    echo "  Physical block sizes differ (${pbs[0]} bytes on the HDD, ${pbs[1]} on the NVMe)."
    echo "  Expected and harmless — LVM aligns to the larger size; the matching"
    echo "  warning is silenced with devices/allow_mixed_block_sizes."
fi

# 0b. Cache chunk size. dm-cache maps the pool in fixed power-of-two chunks and
#     a pool may hold at most allocation/cache_pool_max_chunks of them, so the
#     minimum usable chunk size grows with the pool: LVM computes it in
#     cache_manip.c:update_cache_pool_params as ceil(pool_size / max_chunks)
#     rounded up to a 32K multiple. For 900G that is 960K, hence the hard
#     failure of the old hardcoded 512K (900G/512K = 1843200 chunks).
#     900G -> 1 MiB = 921600 chunks (~17 MiB of pool metadata LV, ~8 bytes per
#     chunk of kernel memory); 1 MiB is also a multiple of the HDD's 4096-byte
#     physical sectors, which is what a 512e backing disk wants.
to_kib() {   # 900G -> KiB; a unit suffix is required so a typo cannot silently
             # turn a 900 GiB pool into 900 KiB
    local s="${1^^}" n unit
    n="${s//[!0-9]/}"; unit="${s//[0-9]/}"
    case "$unit" in
        K|KB) echo "$n" ;;
        M|MB) echo $(( n * 1024 )) ;;
        G|GB) echo $(( n * 1024 * 1024 )) ;;
        T|TB) echo $(( n * 1024 * 1024 * 1024 )) ;;
        *)    echo "Error: cannot parse the size '$1' (use a suffix, e.g. 900G)." >&2; exit 1 ;;
    esac
}

if ! cache_kib=$(to_kib "$CACHE_SIZE") || [ "${cache_kib:-0}" -le 0 ]; then
    echo "Error: CACHE_SIZE='$CACHE_SIZE' did not parse to a positive size." >&2
    exit 1
fi
min_chunk=$(( ((cache_kib + CACHE_MAX_CHUNKS - 1) / CACHE_MAX_CHUNKS + 31) / 32 * 32 ))
chunk=32
while [ "$chunk" -lt "$min_chunk" ] || [ "$chunk" -lt "${CHUNK_SIZE:-0}" ]; do
    chunk=$(( chunk * 2 ))
done
if [ "$chunk" != "${CHUNK_SIZE:-}" ]; then
    echo "Cache chunk size: ${chunk}K (requested '${CHUNK_SIZE:-auto}', minimum for a ${CACHE_SIZE} pool at ${CACHE_MAX_CHUNKS} chunks is ${min_chunk}K)"
fi
CHUNK_SIZE="$chunk"
echo "  ${CACHE_SIZE} cache = $(( cache_kib / CHUNK_SIZE )) x ${CHUNK_SIZE}K chunks (limit ${CACHE_MAX_CHUNKS})"

# Fail here rather than halfway through the rebuild: the pool (plus its
# metadata LV, ~15 bytes per chunk) has to fit on the cache SSD.
cache_dev_kib=$(( $(cat "/sys/class/block/$(basename "$(readlink -f "$CACHE_DEV")")/size") / 2 ))
meta_kib=$(( 4096 + cache_kib / CHUNK_SIZE * 15 / 1024 ))  # 4 MiB + ~15 B/chunk, in KiB
margin_kib=$(( 1024 * 1024 ))                              # label area + rounding
if [ $(( cache_kib + meta_kib )) -gt $(( cache_dev_kib - margin_kib )) ]; then
    echo "Error: ${CACHE_SIZE} pool + ~$(( meta_kib / 1024 )) MiB of metadata does not fit on" >&2
    echo "       $CACHE_DEV ($(( cache_dev_kib / 1024 / 1024 )) GiB available)." >&2
    exit 1
fi

# 0c. Load the cache target. LVM/libdevmapper autoloads this on demand; the
#     explicit modprobe mirrors the old `modprobe bcache` and fails loudly if
#     the module was trimmed out of the image.
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
lvm pvcreate -y --config "$MIXED_BS_CFG" "$BACKING_DEV" "$CACHE_DEV"

# 3. Volume group (LVM-only requirement: cache pool and origin must share a VG).
echo "Creating volume group $VG_NAME..."
lvm vgcreate --config "$MIXED_BS_CFG" "$VG_NAME" "$BACKING_DEV" "$CACHE_DEV"

# 4. Origin LV — all remaining space on the HDD PV (replaces make-bcache -B).
echo "Creating $VG_NAME/$DATA_LV on the backing HDD..."
lvm lvcreate -n "$DATA_LV" -l 100%FREE "$VG_NAME" "$BACKING_DEV"

# 5. Cache pool LV on the NVMe (replaces make-bcache -C).
echo "Creating $VG_NAME/$CACHE_LV (${CACHE_SIZE}, chunk ${CHUNK_SIZE}K) on the cache SSD..."
lvm lvcreate -n "$CACHE_LV" -L "$CACHE_SIZE" --type cache-pool \
    --cachemode "$CACHE_MODE" \
    --poolmetadataspare n \
    --chunksize "$CHUNK_SIZE" \
    --config "allocation { cache_pool_max_chunks = $CACHE_MAX_CHUNKS }" \
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
