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
    echo -e "${BLUE}--- Interactive ZFS Desktop Installation Setup ---${NC}"
    
    # Disk Selection
    echo -e "\n${YELLOW}1. Select the target disk for installation:${NC}"
    mapfile -t disks < <(lsblk -d -n --output NAME,SIZE,MODEL | grep -v "rom")
    if [ ${#disks[@]} -eq 0 ]; then echo -e "${RED}No disks found. Aborting.${NC}"; exit 1; fi
    for i in "${!disks[@]}"; do printf "  %s) %s\n" "$((i+1))" "${disks[$i]}"; done
    
    local choice
    while true; do
        read -p "Enter the number of the disk you want to use: " choice
        if [[ $choice =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#disks[@]}" ]; then
            DISK_NAME=$(echo "${disks[$((choice-1))]}" | awk '{print $1}')
            DISK="/dev/${DISK_NAME}"; echo -e "${GREEN}You have selected: ${DISK}${NC}"; break
        else echo -e "${RED}Invalid selection. Please try again.${NC}"; fi
    done

    # Other Variables
    echo -e "\n${YELLOW}2. Enter system and user configuration values (press Enter for defaults).${NC}"
    read -p "Enter ZFS pool name [rpool]: " POOL_NAME; POOL_NAME=${POOL_NAME:-rpool}
    read -p "Enter hostname [arch-zfs]: " HOSTNAME; HOSTNAME=${HOSTNAME:-arch-zfs}
    read -p "Enter username for your new user [archuser]: " USERNAME; USERNAME=${USERNAME:-archuser}
    read -p "Enter timezone [Asia/Jakarta]: " TIMEZONE; TIMEZONE=${TIMEZONE:-Asia/Jakarta}
    read -p "Enter locale [en_US.UTF-8]: " LOCALE; LOCALE=${LOCALE:-en_US.UTF-8}
    read -p "Enter keymap [us]: " KEYMAP; KEYMAP=${KEYMAP:-us}

    # Final Confirmation
    clear
    echo -e "${BLUE}--- Installation Confirmation ---${NC}"
    echo -e "This will install a full ZFS desktop with automated snapshots, Chaotic-AUR, and ${RED}DESTROY ALL DATA${NC} on the disk."
    echo "----------------------------------------------------"
    echo -e "  Target Disk : ${YELLOW}${DISK}${NC}"
    echo -e "  ZFS Pool Name: ${YELLOW}${POOL_NAME}${NC}"
    echo -e "  Hostname    : ${YELLOW}${HOSTNAME}${NC}"
    echo -e "  Username    : ${YELLOW}${USERNAME}${NC}"
    echo "----------------------------------------------------"
    read -rp "$(echo -e ${RED}"Are you absolutely sure? This cannot be undone. (y/N): "${NC})" confirm
    if [[ "${confirm,,}" != "y" ]]; then echo -e "${YELLOW}Installation aborted.${NC}"; exit 0; fi
}


# --- MAIN SCRIPT EXECUTION ---
configure_installation

# --- 1. PREPARE THE LIVE ENVIRONMENT ---
echo -e "${GREEN}>>> Preparing the live Arch ISO environment...${NC}"
loadkeys "$KEYMAP"
timedatectl set-ntp true
echo ">>> Setting up ArchZFS, Xlibe, and Chaotic-AUR repositories..."
tee -a /etc/pacman.conf <<-'EOF'
[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF
pacman-key --init &>/dev/null
pacman-key --recv-keys --keyserver keyserver.ubuntu.com 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9 &>/dev/null
pacman-key --lsign-key 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9 &>/dev/null
curl -sS https://raw.githubusercontent.com/X11Libre/binpkg-arch-based/refs/heads/main/0x73580DE2EDDFA6D6.gpg | gpg --import - &>/dev/null
pacman-key --lsign-key 73580DE2EDDFA6D6 &>/dev/null
if ! grep -q "\[xlibre\]" /etc/pacman.conf; then
    echo -e "\n[xlibre]\nServer = https://github.com/X11Libre/binpkg-arch-based/raw/refs/heads/main/" | tee -a /etc/pacman.conf
fi
pacman-key --recv-key --keyserver keyserver.ubuntu.com 3056513887B78AEB &>/dev/null
pacman-key --lsign-key 3056513887B78AEB &>/dev/null
pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' &>/dev/null
if ! grep -q "\[chaotic-aur\]" /etc/pacman.conf; then
    echo -e "\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist" | tee -a /etc/pacman.conf
fi
pacman -Sy --noconfirm zfs-linux zfs-utils &>/dev/null
modprobe zfs
sleep 2

# --- 2. DISK PARTITIONING & ZFS SETUP ---
echo -e "${GREEN}>>> Partitioning the disk and creating ZFS pool '$POOL_NAME'...${NC}"
sgdisk --zap-all "$DISK" &>/dev/null
sgdisk -n1:1M:+512M -t1:EF00 "$DISK" &>/dev/null
sgdisk -n2:0:0 -t2:BF00 "$DISK" &>/dev/null
sleep 2
if [[ $DISK == *"nvme"* ]]; then EFI_PART="${DISK}p1"; ZFS_PART="${DISK}p2"; else EFI_PART="${DISK}1"; ZFS_PART="${DISK}2"; fi
zpool create -f -o ashift=12 -o autotrim=on -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=zstd -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=none -R /mnt "$POOL_NAME" "$ZFS_PART"
zfs create -o canmount=noauto -o mountpoint=/ "$POOL_NAME/ROOT/default"
zfs create -o mountpoint=/home "$POOL_NAME/HOME/default"
zfs mount "$POOL_NAME/ROOT/default"

# --- 3. PACKAGE INSTALLATION ---
echo -e "${GREEN}>>> Installing all packages from official repos and Chaotic-AUR...${NC}"
PKG_LIST="base base-devel linux linux-firmware linux-headers zfs-dkms zfs-boot-menu zfs-snap-manager paru-bin limine efibootmgr nano networkmanager curl git sudo"
PKG_LIST+=" alacritty bat brightnessctl bspwm clipcat dunst eza feh fzf thunar tumbler gvfs-mtp firefox geany jq jgmenu kitty libwebp maim mpc mpd mpv neovim ncmpcpp npm pamixer pacman-contrib papirus-icon-theme picom playerctl polybar lxsession-gtk3 python-gobject redshift rofi rustup sxhkd tmux xclip xdg-user-dirs xdo xdotool xsettingsd yazi zsh zsh-autosuggestions zsh-history-substring-search zsh-syntax-highlighting ttf-inconsolata ttf-jetbrains-mono ttf-jetbrains-mono-nerd ttf-terminus-nerd ttf-ubuntu-mono-nerd webp-pixbuf-loader mesa intel-ucode pipewire pipewire-pulse wireplumber pipewire-alsa pipewire-jack bluez bluez-utils power-profiles-daemon ly"
PKG_LIST+=" xlibre-xserver xlibre-xserver-common xlibre-xf86-input-libinput xorg-xinit libbsd"
PKG_LIST+=" visual-studio-code-bin python-pip python-pipx python-virtualenv python-ruff python-black pyright"
PKG_LIST+=" steam heroic-games-launcher-bin gamemode mangohud protonup-qt wine-staging winetricks"
PKG_LIST+=" lib32-mesa lib32-gamemode lib32-mangohud vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader ttf-liberation"
pacstrap -K /mnt ${PKG_LIST} &>/dev/null
mkfs.fat -F32 "$EFI_PART" &>/dev/null
mount --mkdir "$EFI_PART" /mnt/boot/efi

# --- 4. SYSTEM CONFIGURATION ---
echo -e "${GREEN}>>> Configuring the new system...${NC}"
genfstab -U /mnt >> /mnt/etc/fstab
zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"

### CHANGE: Optimize pacman.conf on the new system
echo ">>> Optimizing pacman configuration..."
sed -i 's/^#Color/Color/' /mnt/etc/pacman.conf
sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' /mnt/etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 5/' /mnt/etc/pacman.conf
# Add the ILoveCandy Easter egg under the [options] section
sed -i '/\[options\]/a ILoveCandy' /mnt/etc/pacman.conf

# Add repositories to the new system's pacman.conf
tee -a /mnt/etc/pacman.conf <<-'EOF'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist

[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental

[xlibre]
Server = https://github.com/X11Libre/binpkg-arch-based/raw/refs/heads/main/
EOF

# --- 5. CHROOT AND FINISH CONFIGURATION ---
echo ">>> Chrooting into the new system to finalize setup..."
arch-chroot /mnt /bin/bash <<EOF
set -e
echo ">>> Setting up repository keys on the new system..."
pacman-key --init
pacman-key --populate archlinux
pacman-key --recv-keys --keyserver keyserver.ubuntu.com 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
pacman-key --lsign-key 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
curl -sS https://raw.githubusercontent.com/X11Libre/binpkg-arch-based/refs/heads/main/0x73580DE2EDDFA6D6.gpg | gpg --import -
pacman-key --lsign-key 73580DE2EDDFA6D6
pacman-key --recv-key --keyserver keyserver.ubuntu.com 3056513887B78AEB
pacman-key --lsign-key 3056513887B78AEB
echo ">>> Syncing pacman databases..."
pacman -Sy --noconfirm
echo ">>> Installing Chaotic keyring and mirrorlist packages..."
pacman -S --noconfirm chaotic-keyring chaotic-mirrorlist

echo ">>> Setting system basics (timezone, locale, hostname)..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime && hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen && locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf && echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname
{ echo "127.0.0.1 localhost"; echo "::1 localhost"; echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME"; } >> /etc/hosts

echo -e "${YELLOW}>>> Creating users and passwords...${NC}"
echo "Setting root password:" && passwd
DESKTOP_GROUPS="wheel,adm,log,systemd-journal,rfkill,games,uucp,input"
useradd -m -G "\$DESKTOP_GROUPS" "$USERNAME"
echo "Setting password for user '$USERNAME':" && passwd "$USERNAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo ">>> Configuring mkinitcpio for ZFS..."
sed -i 's/HOOKS=(base udev autodetect modconf block filesystems fsck)/HOOKS=(base udev autodetect modconf block keyboard zfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo ">>> Enabling system services (including ZFS and snapshot tools)..."
systemctl enable NetworkManager.service bluetooth.service ly.service power-profiles-daemon.service
systemctl enable zfs-import-cache.service zfs-mount.service zfs-import.target zsm.service

echo ">>> Configuring ZFS Boot Menu..."
zfs set org.zfsbootmenu:kernel=vmlinuz-linux "$POOL_NAME/ROOT/default"

echo ">>> Downloading and setting up Catppuccin Limine theme..."
THEME_DIR=\$(mktemp -d)
git clone --depth=1 https://github.com/catppuccin/limine.git "\$THEME_DIR"

echo ">>> Configuring Limine bootloader with snapshot recovery option..."
limine-install
cat "\$THEME_DIR/themes/catppuccin-mocha.conf" > /boot/efi/limine.cfg
cat >> /boot/efi/limine.cfg << LIMINE_CFG

# Bootloader settings
TIMEOUT=5

# Boot entries
:Arch Linux (Default)
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    CMDLINE=zfs=${POOL_NAME}/ROOT/default rw quiet loglevel=3
    INITRD_PATH=boot:///intel-ucode.img
    INITRD_PATH=boot:///initramfs-linux.img

:ZFS Snapshots (Recovery)
    PROTOCOL=efi
    IMAGE_PATH=boot:///EFI/zbm/zfsbootmenu.EFI
LIMINE_CFG
rm -rf "\$THEME_DIR"

echo ">>> Configuring Ly display manager with Catppuccin theme..."
cat > /etc/ly/config.ini << LY_CFG
[main]
blank_password = false
blank_username = false
x_cmd = /usr/bin/X
[desktop]
desktop_cmd = /usr/bin/bspwm
[lang]
title = Welcome
username = Username
password = Password
logout_text = logout
shutdown_text = shutdown
restart_text = restart
[theme]
bg = 1E1E2E
fg = CDD6F4
act_bg = 313244
act_fg = F5C2E7
err_bg = 1E1E2E
err_fg = F38BA8
LY_CFG
EOF

# --- 6. FINALIZATION ---
echo -e "\n${GREEN}====================================================="
echo -e "       SYSTEM INSTALLATION COMPLETE"
echo -e "=====================================================${NC}"
umount -R /mnt
zpool export "$POOL_NAME"
echo -e "Your system is configured with a ${YELLOW}ZFS${NC} foundation and ${YELLOW}automated snapshot tools${NC}."
echo -e "${YELLOW}Pacman has been optimized${NC} with parallel downloads and a fun Easter egg."
echo -e "The AUR helper ${YELLOW}paru${NC} is installed and ready to use."
echo -e "${YELLOW}You can now reboot.${NC}"
