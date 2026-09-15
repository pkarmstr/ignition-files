#!/bin/bash
#
# nevua-ketana storage: a 20 TB HDD cached by a 1 TB NVMe, via LVM cache.
#
#   BACKING_DEV  Toshiba 20 TB HDD     -> PV holding lv_data  (the data LV)
#   CACHE_DEV    Crucial P5 Plus 1 TB  -> PV holding lv_cache (the cache pool)
#   /dev/vg_storage/lv_data   XFS, writethrough-cached   <- the filesystem to mount
#   (LVM creates the internal sub-LVs lv_cache_cpool{,_cdata,_cmeta} and
#    lv_data_corig; it manages them, never touch them by hand)
#
# DESTROYS EVERYTHING ON THE TWO DATA DISKS. This is an installer step, run once
# by setup-storage.service, and it does not care what it finds on them: it wipes
# both disks itself before building. The one thing it refuses to touch is the OS
# disk (OS_DEV). ./teardown-storage.sh undoes the result on a running system.
#
# Written for ONE machine, so nothing is probed at runtime; every size below is a
# measured value. Device identifiers: HARDWARE.md. If a disk is ever swapped,
# re-measure the two marked (*). Measured 2026-08-29:
#   HDD   20,000,588,955,648 B = 18.19 TiB, 512 logical / 4096 physical (*)
#   NVMe   1,000,204,886,016 B = 931.51 GiB, 512 logical / 512 physical  (*)
#
#   CACHE_SIZE=900G — the NVMe PV is 931.51 GiB, so 900G leaves ~31 GiB for the
#     pool's metadata LV (measured: 44 MiB), its metadata spare and LVM headroom.
#
#   CHUNK_SIZE=1024 — dm-cache maps the pool in power-of-two chunks and LVM caps
#     a pool at CACHE_MAX_CHUNKS of them, so the minimum chunk grows with the
#     pool: ceil(900 GiB / 1,000,000) = 960 KiB, rounded up to a power of two is
#     1 MiB (921,600 chunks). 512K fails outright with "less than required
#     minimal chunk size 960.00 KiB". 1 MiB is also a multiple of the HDD's
#     4096-byte physical sectors. CACHE_MAX_CHUNKS is pinned on the lvcreate
#     command line so this stays true whatever the distro default is.
#
#   MIXED_BS_CFG — the HDD's 4096-byte *physical* sectors vs the NVMe's 512 make
#     pvcreate/vgcreate warn "WARNING: Devices have inconsistent physical block
#     sizes (4096 and 512)". An LVM cache needs pool and origin in one VG, so the
#     mismatch is inherent and harmless (LVM aligns everything to the larger
#     size); the config silences just that warning. A mismatch of the *logical*
#     block sizes is the one that would matter, and LVM refuses that on its own.
#     Re-check after a disk swap:  lsblk -dno NAME,LOG-SEC,PHY-SEC /dev/sdX
#

# -u as well as -e: every variable below has to actually be set. A misspelled
# or missing assignment here expands to nothing and quietly changes the meaning
# of a chown (":1001" is "set the group", not "set the owner"), so an empty
# value has to be an error, not an argument to a successful-looking command.
set -euo pipefail

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

# Who may read and write the volume (step 10). It is the one user declared in
# the butane `passwd:` section; uid/gid are looked up at run time, never
# hardcoded (see step 10). Mode is left at mkfs' 0755, so the owner gets rwx
# and everyone else r-x; for group-writable, add `chmod g+w` to step 10, and
# for "keelan may write whatever anyone else owns here" use an ACL instead of
# a second chown:  setfacl -m u:$STORAGE_UID:rwx "$MNT_POINT"
STORAGE_OWNER="keelan"
MNT_POINT="/var/mnt/storage"   # must match var-mnt-storage.mount's Where=

[ "$EUID" -eq 0 ] || { echo "Please run as root (sudo)." >&2; exit 1; }

# Kill switch: Ignition writes this file only when it is listed in config.bu.
# Present means the data disks already hold the volume we want to keep: skip
# the destructive work, write the done marker, and let setup-storage.service
# mount the existing volume and disable itself. fetch-models.sh removes the
# file after it checks it, so it never outlives the boot that consumed it.
LOCK_FILE="/var/lib/provision.lock"
if [ -e "$LOCK_FILE" ]; then
    echo "Lock file $LOCK_FILE present: skipping storage setup."
    touch /var/lib/setup-storage.done
    exit 0
fi

for d in "$CACHE_DEV" "$BACKING_DEV"; do
  [ "$d" != "$OS_DEV" ] || { echo "Error: $d is the OS disk." >&2; exit 1; }
  [ -b "$d" ] || { echo "Error: $d not found (check the by-id paths in HARDWARE.md)." >&2; exit 1; }
done

# 1. Free both disks from a previous run of this script. They have to be
#    unmounted and inactive or wipefs fails with "Device or resource busy".
echo "Releasing any previous $VG_NAME..."
systemctl stop var-mnt-storage.mount 2>/dev/null || true
lvm vgchange --activate no "$VG_NAME" >/dev/null 2>&1 || true
lvm lvremove --force "$VG_NAME" >/dev/null 2>&1 || true
lvm vgremove --force "$VG_NAME" >/dev/null 2>&1 || true

# 2. Blank both disks: filesystems, partition tables, old PV labels, RAID
#    members. Doing it here means every later step starts from empty.
echo "Wiping ${BACKING_DEV} and ${CACHE_DEV}..."
wipefs --all "$BACKING_DEV" "$CACHE_DEV"
udevadm settle

# Load the cache target explicitly. LVM would autoload it, but failing here says
# "the module was trimmed out of this image" instead of failing mid-rebuild.
modprobe dm_cache

# 3. Physical volumes.
echo "Creating physical volumes..."
lvm pvcreate --yes --config "$MIXED_BS_CFG" "$BACKING_DEV" "$CACHE_DEV"

# 4. Volume group (LVM-only requirement: cache pool and origin must share a VG).
echo "Creating volume group $VG_NAME..."
lvm vgcreate --config "$MIXED_BS_CFG" "$VG_NAME" "$BACKING_DEV" "$CACHE_DEV"

# 5. Origin LV — all remaining space on the HDD PV.
#    --yes answers the "Wipe it?" confirmation that LVM raises when zeroing finds
#    a signature at the start of the new LV. The step-2 wipefs cannot see that
#    one: it only probes the standard offsets of the whole disk, and this LV
#    starts 1 MiB into it (the PV's first PE). With no answer coming, the prompt
#    defaults to "n" and lvcreate exits 5 with "Failed to wipe start of new LV".
echo "Creating $VG_NAME/$DATA_LV (~18.19 TiB) on the backing HDD..."
lvm lvcreate --yes -n "$DATA_LV" -l 100%FREE "$VG_NAME" "$BACKING_DEV"

# 6. Cache pool LV on the NVMe.
echo "Creating $VG_NAME/$CACHE_LV (${CACHE_SIZE}, chunk ${CHUNK_SIZE}K) on the cache SSD..."
lvm lvcreate --yes -n "$CACHE_LV" -L "$CACHE_SIZE" --type cache-pool \
    --cachemode "$CACHE_MODE" \
    --chunksize "$CHUNK_SIZE" \
    --config "allocation { cache_pool_max_chunks = $CACHE_MAX_CHUNKS }" \
    "$VG_NAME" "$CACHE_DEV"

# 7. Attach the pool to the origin. --zero y is required for unattended runs: LVM
#    asks "Do you want to wipe existing metadata of cache pool ...? [n]" if the
#    pool's metadata area is not known-empty, and with no stdin that prompt
#    aborts the conversion. The cache mode can be changed later with `lvchange
#    --cachemode`, persistently.
echo "Caching $DATA_LV with $CACHE_LV (mode: $CACHE_MODE)..."
lvm lvconvert --type cache --cachepool "$VG_NAME/$CACHE_LV" \
    --cachemode "$CACHE_MODE" --zero y \
    "$VG_NAME/$DATA_LV"

# 8. Give udev a moment to create the mapped device before formatting it.
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

# 9. Format the cached LV with XFS. -f overwrites whatever the LV already holds.
echo "Formatting $DATA_DEV with XFS..."
mkfs.xfs -f "$DATA_DEV"

# 10. Hand the fresh volume to its owner. The root directory's ownership is
#     filesystem *content* — it lives in the XFS root inode, not in the mount —
#     so writing it once here, while the volume is empty, is all it ever takes:
#     every later mount shows the same owner and no unit has to run at boot.
#     The alternative (ExecStartPost=/usr/bin/chown in var-mnt-storage.mount)
#     would re-assert the owner on every boot, hiding any later chown, and it
#     runs as fsadm_t, whose SELinux policy is not written for chowning foreign
#     labels — silently ignored with a '-' prefix, a failed unit without one.
#     setup-storage.service is unconfined_service_t, which may.
#     uid/gid come from id(1) rather than a literal 1000: the uCore image ships
#     its own default user, so the Ignition-created keelan is not guaranteed to
#     be uid 1000, and a wrong number here is an unreadable volume root.
STORAGE_UID=$(id -u "$STORAGE_OWNER")
STORAGE_GID=$(id -g "$STORAGE_OWNER")
echo "Mounting $DATA_DEV on $MNT_POINT to give $STORAGE_OWNER ($STORAGE_UID:$STORAGE_GID) the volume root..."
mkdir -p "$MNT_POINT"
# Same options var-mnt-storage.mount will use, so nothing surprising is cached
# from this first mount; it is unmounted again below and systemd remounts it.
mount -o noatime "$DATA_DEV" "$MNT_POINT"
chown "$STORAGE_UID:$STORAGE_GID" "$MNT_POINT"

# ...and label it. mkfs.xfs writes no security.selinux xattr, so on the first
# mount the root inode has no label of its own and lands on unlabeled_t rather
# than inheriting the mount point's mnt_t — and everything created under it
# inherits unlabeled_t too. It is invisible from this account: unconfined_t
# (keelan, ssh, sudo) is allowed unlabeled_t, so the volume reads and writes
# fine. A confined domain is not — llama-server.container bind-mounts this
# volume as /models, and it would be denied on every file there, with an AVC
# naming a label nobody set on purpose. restorecon applies the policy default
# (/var/mnt -> mnt_t via file_contexts.subs_dist); -F because the current label
# is not a *wrong* default, it is the absence of one. The result is an on-disk
# xattr, so like the ownership it is written once here and every later mount
# shows it. Deliberately not -R: this only ever runs against an empty volume,
# and a recursive relabel would undo the container runtime's own :z relabel.
restorecon -F "$MNT_POINT"

# Verify rather than assume. Ownership and label both live in the filesystem,
# so if either write silently no-oped here the volume is unusable forever and
# nothing downstream reports it: an 18 TiB "Success!" that no one can write to.
VOL_UID=$(stat -c "%u" "$MNT_POINT")
VOL_CTX=$(stat -c "%C" "$MNT_POINT")
if [ "$VOL_UID" != "$STORAGE_UID" ] || [[ "$VOL_CTX" == *unlabeled_t* ]]; then
    echo "Error: $MNT_POINT is not usable: got uid=$VOL_UID context=$VOL_CTX," >&2
    echo "       expected uid=$STORAGE_UID and a real label." >&2
    exit 1
fi
umount "$MNT_POINT"

echo "Success! /dev/$VG_NAME/$DATA_LV is a ${CACHE_MODE}-cached XFS volume, owned by $STORAGE_OWNER."
lvm lvs -a -o+cache_mode,chunk_size "$VG_NAME"

# Nothing else is needed for persistence: lvm2 activates vg_storage (and with it
# the cache) at every boot, the cache mode lives in the LVM metadata, and the
# volume root's ownership and SELinux label live in the filesystem. Verify
# after a reboot with:
#   lvs -o lv_name,cache_mode,cache_size       ls -ldZ /var/mnt/storage
# and, from the account, the thing that actually matters:
#   touch /var/mnt/storage/writetest && rm /var/mnt/storage/writetest
# Mounting is var-mnt-storage.mount's job — see "The storage mount" in README.md.
# If the cache NVMe ever dies: vgreduce --removemissing --force $VG_NAME, then mount.
