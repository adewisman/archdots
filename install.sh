#!/bin/bash
set -euo pipefail # Exit on error

# --- USER-CONFIGURABLE VARIABLES ---
DISK="/dev/disk/by-id/your-target-disk-id"
POOL_NAME="rpool"
HOSTNAME="archzfs"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# --- 1. PREPARE THE LIVE ENVIRONMENT (RUN ON ARCH ISO) ---
echo ">>> Preparing the live Arch ISO environment..."
loadkeys $KEYMAP
timedatectl set-ntp true

echo ">>> Adding the NEW ArchZFS repository..."
### CHANGE: Using the new GitHub-based repository and PGP key
tee -a /etc/pacman.conf <<-'EOF'
[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

### CHANGE: Using the new key import method
echo ">>> Importing and signing the new ArchZFS PGP key..."
pacman-key --init
pacman-key --recv-keys 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
pacman-key --lsign-key 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9

echo ">>> Installing ZFS kernel module and utils on the live ISO..."
# Refresh pacman databases to see the new repo
pacman -Sy --noconfirm zfs-linux zfs-utils

echo ">>> Loading ZFS kernel module..."
modprobe zfs
sleep 2

# --- 2. DISK PARTITIONING ---
echo ">>> Partitioning the disk: $DISK"
sgdisk --zap-all $DISK
sgdisk -n1:1M:+512M -t1:EF00 $DISK   # EFI System Partition
sgdisk -n2:0:0 -t2:BF00 $DISK        # ZFS Partition
sleep 2
EFI_PART="${DISK}-part1"
ZFS_PART="${DISK}-part2"

# --- 3. ZFS POOL AND DATASET CREATION ---
echo ">>> Creating the ZFS pool '$POOL_NAME'..."
zpool create -f -o ashift=12 -o autotrim=on -O acltype=posixacl -O xattr=sa \
    -O dnodesize=auto -O compression=zstd -O normalization=formD -O relatime=on \
    -O canmount=off -O mountpoint=none -R /mnt \
    $POOL_NAME $ZFS_PART

echo ">>> Creating ZFS datasets..."
zfs create -o canmount=noauto -o mountpoint=/ $POOL_NAME/ROOT/default
zfs create -o mountpoint=/home $POOL_NAME/HOME/default
zfs mount $POOL_NAME/ROOT/default

# --- 4. MOUNTING AND BASE INSTALLATION ---
echo ">>> Installing Arch Linux base system (pacstrap)..."
pacstrap -K /mnt base base-devel linux linux-firmware linux-headers zfs-dkms limine efibootmgr nano networkmanager

echo ">>> Formatting and mounting the EFI partition at /mnt/boot/efi..."
mkfs.fat -F32 $EFI_PART
mount --mkdir $EFI_PART /mnt/boot/efi

# --- 5. SYSTEM CONFIGURATION ---
echo ">>> Configuring the new system..."
genfstab -U /mnt >> /mnt/etc/fstab
zpool set cachefile=/etc/zfs/zpool.cache $POOL_NAME

### CHANGE: Add the NEW repository config to the target system
tee -a /mnt/etc/pacman.conf <<-'EOF'
[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

# --- 6. CHROOT AND FINISH CONFIGURATION ---
echo ">>> Chrooting into the new system to finalize setup..."
arch-chroot /mnt /bin/bash <<EOF
set -e

### CHANGE: Initialize pacman keyring and add the ArchZFS key to the NEW system
echo ">>> Initializing keyring and signing ArchZFS key on the new system..."
pacman-key --init
pacman-key --recv-keys 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
pacman-key --lsign-key 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9

echo ">>> Setting timezone, locale, and hostname..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname
# Basic hosts file
{
    echo "127.0.0.1 localhost"
    echo "::1       localhost"
    echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME"
} >> /etc/hosts

echo ">>> SET A ROOT PASSWORD"
passwd

echo ">>> Configuring mkinitcpio for ZFS..."
sed -i 's/HOOKS=(base udev autodetect modconf block filesystems fsck)/HOOKS=(base udev autodetect modconf block keyboard zfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo ">>> Enabling essential services..."
systemctl enable NetworkManager.service
systemctl enable zfs-import-cache.service
systemctl enable zfs-mount.service
systemctl enable zfs-import.target

echo ">>> Installing Limine bootloader..."
limine-install

echo ">>> Creating Limine configuration..."
cat > /boot/efi/limine.cfg << 'LIMINE_CFG'
TIMEOUT=3
:Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    INITRD_PATH=boot:///initramfs-linux.img
    CMDLINE=zfs=$POOL_NAME/ROOT/default rw
LIMINE_CFG
sed -i "s/\$POOL_NAME/$POOL_NAME/g" /boot/efi/limine.cfg

EOF

# --- 7. FINALIZATION ---
echo "Installation finished. Unmounting..."
umount -R /mnt
zpool export $POOL_NAME
echo "You can now reboot."
# reboot
