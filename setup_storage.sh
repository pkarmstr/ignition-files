#!/bin/bash
#!/bin/bash
set -e          # Exit immediately if any command fails
set -o pipefail # Exit if any command in a pipeline fails

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

# Define your cache (SSD) and backing (HDD) devices
CACHE_DEV="/dev/disk/by-id/nvme-CT1000P510SSD8_2537E9CABC5C"
BACKING_DEV="/dev/disk/by-id/wwn-0x5000039e58d0650e"

TARGET_DIR="/mnt/storage" 

echo "Loading bcache kernel module..."
modprobe bcache

# 1. Format and automatically link both devices simultaneously
echo "Creating bcache0 device..."
make-bcache -C "$CACHE_DEV" -B "$BACKING_DEV"

# 2. Force udev to process the new block device events
echo "Waiting for /dev/bcache0 to settle..."
udevadm settle

# 3. Apply the runtime change immediately for the installer session
if [ -e "/sys/block/bcache0/bcache/cache_mode" ]; then
    echo "Setting runtime cache mode to writearound..."
    echo writearound > /sys/block/bcache0/bcache/cache_mode
else
    echo "Error: /dev/bcache0 was not initialized correctly." >&2
    exit 1
fi

# 4. Format the new bcache device with XFS
echo "Formatting /dev/bcache0 with XFS..."
mkfs.xfs -f /dev/bcache0

# 5. Mount the drive to continue your installation process
echo "Mounting bcache0 to $TARGET_DIR..."
mkdir -p "$TARGET_DIR"
mount /dev/bcache0 "$TARGET_DIR"

# 6. Configure persistence for the installed target system
echo "Configuring persistent writearound rule for the installed system..."
mkdir -p "$TARGET_DIR/etc/udev/rules.d"
echo 'ACTION=="add", SUBSYSTEM=="block", KERNEL=="bcache*", ATTR{bcache/cache_mode}="writearound"' > "$TARGET_DIR/etc/udev/rules.d/10-bcache-writearound.rules"

echo "Success! /dev/bcache0 is formatted with XFS."
