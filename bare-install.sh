#!/bin/bash
set -euo pipefail

# --- Color Codes for Better Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- INTERACTIVE SETUP FUNCTION ---
configure_installation() {
  clear
  echo -e "${BLUE}--- Interactive Installation Setup ---${NC}"

  # --- Disk Selection ---
  echo -e "\n${YELLOW}1. Select the target disk for installation:${NC}"
  mapfile -t disks < <(lsblk -d -n --output NAME,SIZE,MODEL | grep -v "rom")
  if [ ${#disks[@]} -eq 0 ]; then
    echo -e "${RED}No disks found. Aborting.${NC}"
    exit 1
  fi
  for i in "${!disks[@]}"; do
    printf "  %s) %s\n" "$((i + 1))" "${disks[$i]}"
  done

  local choice
  while true; do
    read -p "Enter the number of the disk you want to use: " choice
    if [[ $choice =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#disks[@]}" ]; then
      DISK_NAME=$(echo "${disks[$((choice - 1))]}" | awk '{print $1}')
      DISK="/dev/${DISK_NAME}"
      echo -e "${GREEN}You have selected: ${DISK}${NC}"
      break
    else
      echo -e "${RED}Invalid selection. Please try again.${NC}"
    fi
  done

  # --- Other Variables ---
  echo -e "\n${YELLOW}2. Enter system and user configuration values (press Enter for defaults).${NC}"
  read -p "Enter ZFS pool name [rpool]: " POOL_NAME
  POOL_NAME=${POOL_NAME:-rpool}
  read -p "Enter hostname [archzfs]: " HOSTNAME
  HOSTNAME=${HOSTNAME:-archzfs}
  read -p "Enter username for your new user [archuser]: " USERNAME
  USERNAME=${USERNAME:-archuser}

  echo "For Timezone, find your region/city from 'timedatectl list-timezones'"
  ### CHANGE: Default timezone is now Asia/Jakarta
  read -p "Enter timezone [Asia/Jakarta]: " TIMEZONE
  TIMEZONE=${TIMEZONE:-Asia/Jakarta}

  echo "For Locale, check '/etc/locale.gen'"
  read -p "Enter locale [en_US.UTF-8]: " LOCALE
  LOCALE=${LOCALE:-en_US.UTF-8}

  echo "For Keymap, find yours from 'ls /usr/share/kbd/keymaps/**/*.map.gz'"
  read -p "Enter keymap [us]: " KEYMAP
  KEYMAP=${KEYMAP:-us}

  # --- Final Confirmation ---
  clear
  echo -e "${BLUE}--- Installation Confirmation ---${NC}"
  echo -e "This will ${RED}DESTROY ALL DATA${NC} on the selected disk."
  echo "----------------------------------------------------"
  echo -e "  Target Disk : ${YELLOW}${DISK}${NC}"
  echo -e "  ZFS Pool Name: ${YELLOW}${POOL_NAME}${NC}"
  echo -e "  Hostname    : ${YELLOW}${HOSTNAME}${NC}"
  echo -e "  Username    : ${YELLOW}${USERNAME}${NC}"
  echo -e "  Timezone    : ${YELLOW}${TIMEZONE}${NC}"
  echo -e "  Locale      : ${YELLOW}${LOCALE}${NC}"
  echo -e "  Keymap      : ${YELLOW}${KEYMAP}${NC}"
  echo "----------------------------------------------------"

  read -rp "$(echo -e ${RED}"Are you absolutely sure you want to proceed? (y/N): "${NC})" confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo -e "${YELLOW}Installation aborted by user.${NC}"
    exit 0
  fi
}

# --- MAIN SCRIPT EXECUTION ---
configure_installation

# --- 1. PREPARE THE LIVE ENVIRONMENT ---
echo -e "${GREEN}>>> Preparing the live Arch ISO environment...${NC}"
loadkeys "$KEYMAP"
timedatectl set-ntp true
tee -a /etc/pacman.conf <<-'EOF'
[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF
pacman-key --init
pacman-key --recv-keys 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
pacman-key --lsign-key 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
pacman -Sy --noconfirm zfs-linux zfs-utils
modprobe zfs
sleep 2

# --- 2. DISK PARTITIONING ---
echo -e "${GREEN}>>> Partitioning the disk: $DISK...${NC}"
sgdisk --zap-all "$DISK"
sgdisk -n1:1M:+1G -t1:EF00 "$DISK"
sgdisk -n2:0:0 -t2:BF00 "$DISK"
sleep 2
if [[ $DISK == *"nvme"* ]]; then
  EFI_PART="${DISK}p1"
  ZFS_PART="${DISK}p2"
else
  EFI_PART="${DISK}1"
  ZFS_PART="${DISK}2"
fi

# --- 3. ZFS POOL AND DATASET CREATION ---
echo -e "${GREEN}>>> Creating the ZFS pool '$POOL_NAME'...${NC}"
zpool create -f -o ashift=12 -o autotrim=on -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=zstd -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=none -R /mnt "$POOL_NAME" "$ZFS_PART"
zfs create -o canmount=noauto -o mountpoint=/ "$POOL_NAME/ROOT/default"
zfs create -o mountpoint=/home "$POOL_NAME/HOME/default"
zfs mount "$POOL_NAME/ROOT/default"

# --- 4. MOUNTING AND BASE INSTALLATION ---
echo -e "${GREEN}>>> Installing Arch Linux base system (pacstrap)...${NC}"
pacstrap -K /mnt base base-devel linux linux-firmware linux-headers zfs-dkms limine efibootmgr nano networkmanager nmcli curl git sudo
mkfs.fat -F32 "$EFI_PART"
mount --mkdir "$EFI_PART" /mnt/boot/efi

# --- 5. SYSTEM CONFIGURATION ---
echo -e "${GREEN}>>> Configuring the new system...${NC}"
genfstab -U /mnt >>/mnt/etc/fstab
zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"
tee -a /mnt/etc/pacman.conf <<-'EOF'
[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

# --- 6. CHROOT AND FINISH CONFIGURATION ---
echo ">>> Copying Wi-Fi profiles to new system..."
mkdir -p /mnt/etc/NetworkManager/system-connections
for file in /var/lib/iwd/*.psk; do
  if [ -f "$file" ]; then
    SSID=$(basename "$file" .psk)
    PSK=$(grep -v '^#' "$file" | sed -n 's/Passphrase=//p')
    cat >"/mnt/etc/NetworkManager/system-connections/${SSID}.nmconnection" <<EOF
[connection]
id=${SSID}
type=wifi
interface-name=wlan0

[wifi]
mode=infrastructure
ssid=${SSID}

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=${PSK}

[ipv4]
method=auto

[ipv6]
method=auto
EOF
    chmod 600 "/mnt/etc/NetworkManager/system-connections/${SSID}.nmconnection"
  fi
done

echo ">>> Chrooting into the new system to finalize setup..."
arch-chroot /mnt /bin/bash <<EOF
set -e
echo ">>> Initializing keyring and signing ArchZFS key..."
pacman-key --init
pacman-key --recv-keys 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
pacman-key --lsign-key 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9

echo ">>> Setting timezone, locale, and hostname..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname
{ echo "127.0.0.1 localhost"; echo "::1       localhost"; echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME"; } >> /etc/hosts

echo -e "${YELLOW}>>> SET A ROOT PASSWORD${NC}"
passwd

echo -e "${YELLOW}>>> Creating user '$USERNAME'...${NC}"
DESKTOP_GROUPS="wheel,adm,log,systemd-journal,rfkill,games,uucp,input"
useradd -m -G "\$DESKTOP_GROUPS" "$USERNAME"

echo -e "${YELLOW}>>> SET A PASSWORD FOR USER '$USERNAME'${NC}"
passwd "$USERNAME"

echo ">>> Enabling sudo for the 'wheel' group..."
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo ">>> Configuring mkinitcpio for ZFS..."
sed -i 's/HOOKS=(base udev autodetect modconf block filesystems fsck)/HOOKS=(base udev autodetect modconf block keyboard zfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo ">>> Enabling essential services..."
systemctl enable NetworkManager.service
systemctl enable systemd-resolved.service
systemctl enable zfs-import-cache.service
systemctl enable zfs-mount.service
systemctl enable zfs-import.target

echo ">>> Disabling DNSSEC..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/dnssec.conf <<'EODNS'
[Resolve]
DNSSEC=no
EODNS


echo ">>> Installing Limine bootloader..."
limine-install
cat > /boot/efi/limine.cfg << LIMINE_CFG
TIMEOUT=3
:Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    INITRD_PATH=boot:///initramfs-linux.img
    CMDLINE=zfs=${POOL_NAME}/ROOT/default rw
LIMINE_CFG
EOF

# --- 7. FINALIZATION ---
echo -e "${GREEN}Installation finished successfully!${NC}"
umount -R /mnt
zpool export "$POOL_NAME"
echo -e "${YELLOW}You can now reboot and log in as user '${USERNAME}'.${NC}"
