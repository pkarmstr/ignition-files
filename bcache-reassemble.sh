#!/bin/bash
# Reassemble bcache on boot. The kernel does not auto-assemble bcache sets.
# Exits 0 quietly when no bcache is present (safe on machines without bcache).
set -euo pipefail

CACHE_DEV="/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C"
BACKING_DEV="/dev/disk/by-id/wwn-0x5000039e58d0650e"

# Wait for udev by-id symlinks (up to 30 s)
for _ in $(seq 1 30); do
  [ -b "$CACHE_DEV" ] && [ -b "$BACKING_DEV" ] && break
  sleep 1
done
[ -b "$CACHE_DEV" ] && [ -b "$BACKING_DEV" ] || exit 0

# Only proceed if both devices carry bcache superblocks
blkid -p "$CACHE_DEV" 2>/dev/null | grep -q "TYPE=bcache" || exit 0
blkid -p "$BACKING_DEV" 2>/dev/null | grep -q "TYPE=bcache" || exit 0

modprobe bcache || exit 1

CACHE_UUID=$(bcache-super-show "$CACHE_DEV" | grep -m1 '^UUID:' | awk '{print $2}')
BACKING_UUID=$(bcache-super-show "$BACKING_DEV" | grep -m1 '^UUID:' | awk '{print $2}')
[ -n "$CACHE_UUID" ] && [ -n "$BACKING_UUID" ] || { echo "ERROR: could not read bcache UUIDs" >&2; exit 1; }

# Already assembled?
for d in "/sys/fs/bcache/$BACKING_UUID" "/sys/fs/bcache/$CACHE_UUID"; do
  [ -e "$d/cache_dev" ] && { echo "bcache already assembled"; exit 0; }
done

# Register cache with backing device (standard reassembly procedure).
# Try the backing's own uuid first, then the cache-set uuid, then any detached backing entry.
if [ -f "/sys/fs/bcache/$BACKING_UUID/register" ]; then
  echo "$CACHE_UUID" > "/sys/fs/bcache/$BACKING_UUID/register"
elif [ -f "/sys/fs/bcache/$CACHE_UUID/register" ]; then
  echo "$CACHE_UUID" > "/sys/fs/bcache/$CACHE_UUID/register"
else
  registered=0
  for d in /sys/fs/bcache/*/; do
    if [ -e "$d/backing_dev" ] && [ ! -e "$d/cache_dev" ] && [ -f "$d/register" ]; then
      echo "$CACHE_UUID" > "$d/register"
      registered=1
      break
    fi
  done
  [ "$registered" -eq 1 ] || { echo "ERROR: no detached bcache backing entry found in /sys/fs/bcache" >&2; exit 1; }
fi

# Wait for the combined device, identified by size (bcache presents backing capacity)
BACKING_SECTORS=$(blockdev --getsz "$BACKING_DEV")
for _ in $(seq 1 15); do
  for d in /dev/bcache*; do
    [ -b "$d" ] || continue
    [ "$(blockdev --getsz "$d")" -eq "$BACKING_SECTORS" ] && { echo "bcache reassembled: $d"; exit 0; }
  done
  sleep 1
done
echo "ERROR: bcache device did not appear after registration" >&2
exit 1
