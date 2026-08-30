#!/bin/bash
#
# teardown_storage.sh — undo setup_storage.sh on nevua-ketana.
#
# Unmounts the cached volume, removes vg_storage (lv_data + lv_cache pool and
# their internal cvol/corig LVs), clears the PV labels, and zeroes the first
# and last 64 MiB of both disks so no XFS / LVM / dm-cache / old bcache
# signature survives. The 512 GB white-label NVMe (OS disk) is NEVER touched.
#
# WARNING: destructive and irreversible.
#
# Usage:  sudo ./teardown_storage.sh          # prompts for confirmation
#         sudo ./teardown_storage.sh --yes    # no prompt (scripted use)

set -eo pipefail

VG_NAME="vg_storage"

# Same device paths as setup_storage.sh — HDD + the 1 TB cache NVMe only.
DEVICES=(
    "/dev/disk/by-id/wwn-0x5000039e58d0650e"            # Toshiba 20 TB HDD
    "/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C"  # Crucial P5 Plus 1 TB
)

# Absolute safety rail: refuse to operate on anything that carries the OS.
FORBIDDEN="/dev/disk/by-id/nvme-PCIe_SSD_20090851200275"

ZERO_MB=64

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

[ "$EUID" -eq 0 ] || { echo "Please run as root (sudo)." >&2; exit 1; }

for d in "${DEVICES[@]}"; do
    [ "$d" != "$FORBIDDEN" ] || { echo "Error: $d is the OS disk." >&2; exit 1; }
    [ -b "$d" ] || { echo "Error: $d not found (check by-id paths in HARDWARE.md)." >&2; exit 1; }
done

echo "This will DESTROY the LVM cache volume '$VG_NAME' and wipe:"
for d in "${DEVICES[@]}"; do echo "  $d"; done
lsblk -o NAME,SIZE,MODEL -d "$FORBIDDEN" 2>/dev/null | sed '1d; s/^/  OS disk untouched: /' || true
echo "ALL DATA ON THE 20 TB HDD WILL BE LOST."

if [ "$ASSUME_YES" != "1" ]; then
    read -r -p "Type 'WIPE' to continue: " reply
    [ "$reply" = "WIPE" ] || { echo "Aborted."; exit 1; }
fi

# 1. Unmount anything living on the volume (also catches bind mounts / swap).
echo "Unmounting filesystems on $VG_NAME..."
if command -v findmnt >/dev/null; then
    while read -r tgt; do
        [ -n "$tgt" ] || continue
        echo "  umount $tgt"
        umount --recursive "$tgt" 2>/dev/null || umount -l "$tgt"
    done < <(findmnt -rn -o TARGET -S "/dev/$VG_NAME/lv_data" 2>/dev/null
             findmnt -rn -o TARGET -S "/dev/mapper/${VG_NAME}-lv_data" 2>/dev/null)
fi
swapoff -a 2>/dev/null || true

# 2. Deactivate then remove the LVs (lvremove on the cached LV also tears down
#    the cache pool and the internal lv_data_cvol / lv_data_corig / *_meta LVs).
if lvm vgdisplay "$VG_NAME" >/dev/null 2>&1; then
    echo "Deactivating logical volumes..."
    lvm lvchange -an "$VG_NAME" 2>/dev/null || true
    lvm vgchange -an "$VG_NAME" 2>/dev/null || true

    echo "Removing logical volumes in $VG_NAME..."
    lvm lvremove -f -y "$VG_NAME" 2>/dev/null || true
    echo "Removing volume group $VG_NAME..."
    lvm vgremove -f -y "$VG_NAME" 2>/dev/null || true
else
    echo "VG $VG_NAME does not exist; nothing to remove."
fi

# 3. Drop the PV labels so the disks look empty to LVM on the next run.
echo "Wiping PV labels..."
for d in "${DEVICES[@]}"; do
    lvm pvremove -f -y "$d" 2>/dev/null || true
done

# 4. Nuke leftover device-mapper nodes (unclean shutdowns can leave orphans).
for m in /dev/mapper/${VG_NAME}-*; do
    [ -e "$m" ] || continue
    echo "  removing stale $m"
    dmsetup remove -f "$m" 2>/dev/null || true
done

# 5. Clear filesystem / partition / raid signatures on both disks.
echo "Clearing signatures (wipefs)..."
for d in "${DEVICES[@]}"; do
    wipefs -a "$d" || true
done

# 6. Zero the head and tail of each disk: primary GPT + LVM label at the start,
#    backup GPT / dm-cache & bcache supers at the end.
echo "Zeroing first and last ${ZERO_MB} MiB of each disk..."
for d in "${DEVICES[@]}"; do
    size_bytes=$(blockdev --getsize64 "$d")
    dd if=/dev/zero of="$d" bs=1M count="$ZERO_MB" conv=notrunc status=none
    tail_sectors=$(( (size_bytes / 512) - (ZERO_MB * 2048) ))
    [ "$tail_sectors" -gt 0 ] &&
        dd if=/dev/zero of="$d" bs=512 seek="$tail_sectors" count=$(( ZERO_MB * 2048 )) \
           conv=notrunc status=none
done

# 7. Rescan so udev agrees the disks are blank.
udevadm settle
partprobe 2>/dev/null || true
blockdev --rereadpt "${DEVICES[0]}" 2>/dev/null || true

echo
echo "Done. Both disks should now report no filesystem or LVM member:"
lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS -d "${DEVICES[@]}" || true
blkid "${DEVICES[@]}" || echo "  (blkid: clean — no signatures)"
lvm pvs 2>/dev/null || true

# To rebuild: run ./setup_storage.sh (it expects blank disks and does no
# wipefs of its own), or reboot into Ignition for the full provisioning chain.
