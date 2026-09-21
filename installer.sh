#!/bin/bash

set -e

echo "+-----------------------+"
echo "| MrrpOS Installer v1.1 |"
echo "+-----------------------+"

echo ""
echo "https://anw.is-a.dev/mrrpos"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "Hold up! You are not root. Please run the installer with root privileges."
    exit 1
fi

echo "Welcome to the MrrpOS Installer. Let's get you set up, shall we?"
echo "First, let's find your MrrpOS archive."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_FILE=$(ls "$SCRIPT_DIR"/*.tar.zstd 2>/dev/null | head -n 1)

if ! command -v zstd &> /dev/null; then
    echo "Could not find 'zstd' command. Please install zstd from your package manager and try again."
    exit 1
fi

if [ -z "$ARCHIVE_FILE" ]; then
    echo "Welp, no MrrpOS archive (.tar.zstd) was found in $SCRIPT_DIR."
    echo "Did you even get one from the website?"
    exit 1
fi

echo "Look, we found a MrrpOS archive: $(basename "$ARCHIVE_FILE")"
read -p "Is this the correct archive? (y/N): " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Please make sure you have the correct archive in this folder and try again."
    echo "As a side note, keep ONLY ONE MrrpOS archive in this folder if you have multiple during installation."
    exit 0
fi
echo ""
echo "Found these devices attached to your machine:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS
echo ""

echo "Please determine which of these is your target partition by looking carefully at their descriptions."
read -p "When you are sure, enter your target partition (e.g., /dev/sdb1): " TARGET_DEV

if [ ! -b "$TARGET_DEV" ]; then
    echo "Oh no. The device node '$TARGET_DEV' seems to either not exist or is not a block device."
    echo "Please figure out your device and try again."
    exit 1
fi

if [ "$TARGET_DEV" = "$(findmnt -n -o SOURCE /)" ]; then
    echo "No. Just no. $TARGET_DEV is your currently active root filesystem."
    echo "Aborting to prevent a suicidal installation."
    exit 1
fi

echo ""
echo "!!! WARNING !!!"
echo "This operation will permanently ERASE ALL DATA on $TARGET_DEV and format it as ext4 (with LABEL=MRRPOS)."
echo "Make sure you don't have any important data left on this device. Also make sure this is your target device."
read -p "Are you absolutely sure you want to proceed? (y/N): " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Installation aborted by user."
    exit 0
fi

echo ""
echo "NOTE: You are advised to let go of your machine for the rest of the installation process."

if mountpoint -q "$TARGET_DEV" 2>/dev/null; then
    echo "Please wait while $TARGET_DEV is being unmounted..."
    umount "$TARGET_DEV"
fi

echo "Formatting $TARGET_DEV with an ext4 filesystem (with LABEL=MRRPOS)..."
mkfs.ext4 -F -L MRRPOS "$TARGET_DEV"

MOUNT_POINT="/mnt/mrrpos_intermediate"
mkdir -p "$MOUNT_POINT"

echo "Mounting $TARGET_DEV to intermediate mount point $MOUNT_POINT..."
mount "$TARGET_DEV" "$MOUNT_POINT"

cleanup() {
    tput cnorm 2>/dev/null || true
    echo ""
    echo "Cleaning up intermediate mount point..."
    sync
    umount "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

echo "Extracting MrrpOS archive to $TARGET_DEV may take a while, huh."
echo "In the mean time, enjoy this spinny thing. Cool, right?"
export ZSTD_NBTHREADS=0

tar --use-compress-program="zstd -T0" -x -p -f "$ARCHIVE_FILE" -C "$MOUNT_POINT" &
TAR_PID=$!

tput civis 2>/dev/null || true

SPINNER=('|' '/' '-' '\')
i=0
while kill -0 "$TAR_PID" 2>/dev/null; do
    printf "\r[%s] Extracting files to $TARGET_DEV..." "${SPINNER[i]}"
    i=$(( (i + 1) % 4 ))
    sleep 0.1
done

wait "$TAR_PID"
TAR_EXIT=$?

tput cnorm 2>/dev/null || true
printf "\r[✓] Extraction process complete!                          \n"

if [ $TAR_EXIT -ne 0 ]; then
    echo "OH NO! Extraction failed with exit code $TAR_EXIT."
    exit 1
fi

echo "Performing target post-install cleanup..."
rm -rf "$MOUNT_POINT"/tmp/* 2>/dev/null || true
rm -rf "$MOUNT_POINT"/usr/lib/firmware/* 2>/dev/null || true
rm -rf "$MOUNT_POINT"/sources/* 2>/dev/null || true

echo "Fetching your PARTUUID for $TARGET_DEV..."
TARGET_PARTUUID=$(blkid -s PARTUUID -o value "$TARGET_DEV")

if [ -z "$TARGET_PARTUUID" ]; then
    echo "Hey, so... could not fetch PARTUUID for your $TARGET_DEV device. Falling back to device path."
    ROOT_PARAM="root=$TARGET_DEV"
    FSTAB_ROOT="$TARGET_DEV"
    echo "This might get messy later on a different configuration of devices and ports."
else
    echo "Found PARTUUID: $TARGET_PARTUUID"
    ROOT_PARAM="root=PARTUUID=$TARGET_PARTUUID"
    FSTAB_ROOT="PARTUUID=$TARGET_PARTUUID"
fi

echo "Overwriting /boot/grub/grub.cfg on target partition..."
mkdir -p "$MOUNT_POINT/boot/grub"

cat > "$MOUNT_POINT/boot/grub/grub.cfg" << EOF
# Begin /boot/grub/grub.cfg
set default=0
set timeout=5

insmod part_msdos
insmod part_gpt
insmod ext2
set root=(hd0,1)
set gfxpayload=1024x768x32

menuentry "MrrpOS 2026.1 (minimrrp), Linux 6.18.10-lfs-13.0-systemd" {
        linux   /boot/vmlinuz-6.18.10-lfs-13.0-systemd $ROOT_PARAM rootdelay=10 rw quiet drm.panic_bg_color=0x3d007a drm.panic_fg_color=0xffffff
}

menuentry "MrrpOS 2026.1 (minimrrp), Linux 6.18.10-lfs-13.0-systemd (Recovery Mode)" {
        linux   /boot/vmlinuz-6.18.10-lfs-13.0-systemd $ROOT_PARAM rootdelay=10 rw drm.panic_bg_color=0x3d007a drm.panic_fg_color=0xffffff
}
EOF

echo "Writing /etc/fstab on target partition..."
mkdir -p "$MOUNT_POINT/etc"

cat > "$MOUNT_POINT/etc/fstab" << EOF
# /etc/fstab: static file system information for MrrpOS
# <file system>             <mount point>   <type>      <options>               <dump>  <pass>
$FSTAB_ROOT               /               ext4        noatime,errors=remount-ro 0       1
tmpfs                       /tmp            tmpfs       nosuid,nodev            0       0
EOF

echo ""
echo "Congratulations! MrrpOS was successfully installed onto your device."
echo "You can now safely remove the installation media by ejecting it and reboot into MrrpOS."