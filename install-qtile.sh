#!/bin/bash
set -euo pipefail

LOGFILE="/tmp/install-qtile.log"
exec 2> >(tee -a "$LOGFILE" >&2)

# --- Color Codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Fail on missing dependency ---
require() {
    command -v "$1" &>/dev/null || { echo -e "${RED}Missing dependency: $1. Please install it first.${NC}"; exit 1; }
}

# --- Error Handling ---
fail() {
    echo -e "${RED}$1${NC}"
    exit 1
}

# --- Hardware Checks ---
check_uefi() {
    if [ ! -d /sys/firmware/efi ]; then
        echo -e "${RED}System is NOT booted in UEFI mode. EFI setup may fail.${NC}"
        read -n1 -r -p "Continue anyway? [y/N]: " choice
        [[ "${choice,,}" == "y" ]] || exit 1
    fi
}

check_network() {
    if ! ping -c 1 archlinux.org &>/dev/null; then
        fail "No network connection detected. Please connect to the Internet before running."
    fi
}

check_disk() {
    local disk="$1"
    if ! [ -b "$disk" ]; then
        fail "Disk device $disk does not exist."
    fi
    if smartctl -a "$disk" | grep -q "SMART overall-health: FAILED"; then
        fail "Disk $disk failed SMART health check!"
    fi
}

# --- Dialog-based User Experience ---
select_disk_dialog() {
    local disks
    disks=$(lsblk -d -n --output NAME,SIZE,MODEL | grep -v "rom")
    local disk_array=()
    while IFS= read -r line; do
        disk_array+=("$line" "")
    done <<< "$disks"
    local choice
    if command -v dialog &>/dev/null; then
        choice=$(dialog --clear --stdout --title "Disk Selection" --menu "Select target disk for installation:" 15 60 6 "${disk_array[@]}")
    else
        echo -e "${YELLOW}Available disks:${NC}"
        select disk in ${disks}; do
            choice="${disk%% *}"
            break
        done
    fi
    echo "$choice"
}

confirm_dialog() {
    local message="$1"
    if command -v dialog &>/dev/null; then
        dialog --yesno "$message" 10 40
        return $?
    else
        read -p "$message [y/N]: " confirm
        [[ "${confirm,,}" == "y" ]]
    fi
}

# ---------------- Script Functions ----------------

import_key() {
    local KEYID="$1"
    local SERVERS=("keyserver.ubuntu.com" "hkp://pool.sks-keyservers.net" "pgp.mit.edu")
    for server in "${SERVERS[@]}"; do
        if pacman-key --recv-keys --keyserver "$server" "$KEYID"; then
            pacman-key --lsign-key "$KEYID" && return 0
        fi
    done
    fail "Failed to import key $KEYID from all keyservers."
}

setup_repos_and_keys() {
    echo -e "${GREEN}>>> Setting up ArchZFS, Xlibre, and Chaotic-AUR repositories...${NC}"
    pacman -Sy --noconfirm dirmngr

    # archzfs repo
    grep -q "^\[archzfs\]" /etc/pacman.conf || tee -a /etc/pacman.conf <<-'EOF'
[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOF

    # Xlibre repo
    grep -q "^\[xlibre\]" /etc/pacman.conf || echo -e "\n[xlibre]\nServer = https://github.com/X11Libre/binpkg-arch-based/raw/refs/heads/main/" | tee -a /etc/pacman.conf

    # Chaotic-AUR
    pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
    grep -q "^\[chaotic-aur\]" /etc/pacman.conf || echo -e "\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist" | tee -a /etc/pacman.conf

    # Keyring initialization if needed
    if [ ! -d /etc/pacman.d/gnupg ] || [ -z "$(ls -A /etc/pacman.d/gnupg)" ]; then
        pacman-key --init
        pacman-key --populate archlinux
    fi

    # Import repo keys
    import_key "3A9917BF0DED5C13F69AC68FABEC0A1208037BE9"
    curl -sS https://raw.githubusercontent.com/X11Libre/binpkg-arch-based/refs/heads/main/0x73580DE2EDDFA6D6.gpg | gpg --import -
    pacman-key --lsign-key 73580DE2EDDFA6D6 || fail "Failed to sign Xlibre key"
    import_key "3056513887B78AEB"
}

partition_and_zfs() {
    echo -e "${GREEN}>>> Partitioning the disk and creating ZFS pool '${POOL_NAME}'...${NC}"
    sgdisk --zap-all "$DISK"
    sgdisk -n1:1M:+512M -t1:EF00 "$DISK"
    sgdisk -n2:0:0 -t2:BF00 "$DISK"
    sleep 2
    if [[ $DISK == *"nvme"* ]]; then
        EFI_PART="${DISK}p1"; ZFS_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"; ZFS_PART="${DISK}2"
    fi
    zpool create -f -o ashift=12 -o autotrim=on -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=zstd -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=none -R /mnt "$POOL_NAME" "$ZFS_PART"
    zfs create -o canmount=noauto -o mountpoint=/ "$POOL_NAME/ROOT/default"
    zfs create -o mountpoint=/home "$POOL_NAME/HOME/default"
    zfs mount "$POOL_NAME/ROOT/default"
}

install_packages() {
    echo -e "${GREEN}>>> Installing all packages for the ZFS & Cozytile desktop...${NC}"
    PKG_LIST="base base-devel linux linux-firmware linux-headers zfs-dkms zfs-boot-menu zfs-snap-manager paru-bin limine efibootmgr nano networkmanager curl git sudo reflector"
    PKG_LIST+=" qtile python-psutil picom dunst zsh starship mpd ncmpcpp playerctl brightnessctl alacritty pfetch htop flameshot thunar roficlip rofi ranger cava neovim vim feh ly noto-fonts pipewire pipewire-pulse wireplumber pavucontrol"
    PKG_LIST+=" pywal-git"
    PKG_LIST+=" xlibre-xserver xlibre-xserver-common xlibre-xf86-input-libinput xorg-xinit"
    PKG_LIST+=" mesa intel-ucode bluez bluez-utils power-profiles-daemon firefox"
    PKG_LIST+=" xorg-xwayland qt6-wayland glfw-wayland wl-clipboard swaylock swaybg wofi waybar wdisplays grim slurp"
    PKG_LIST+=" xdg-desktop-portal xdg-desktop-portal-wlr"
    pacstrap -K /mnt ${PKG_LIST}
    mkfs.fat -F32 "$EFI_PART"
    mount --mkdir "$EFI_PART" /mnt/boot/efi
}

configure_system() {
    echo -e "${GREEN}>>> Configuring the new system...${NC}"
    genfstab -U /mnt >> /mnt/etc/fstab
    zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"
    sed -i 's/^#Color/Color/' /mnt/etc/pacman.conf
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /mnt/etc/pacman.conf
    sed -i '/\[options\]/a ILoveCandy' /mnt/etc/pacman.conf
    tee -a /mnt/etc/pacman.conf <<-'EOF'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist

[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental

[xlibre]
Server = https://github.com/X11Libre/binpkg-arch-based/raw/refs/heads/main/
EOF
}

finalize_in_chroot() {
arch-chroot /mnt /bin/bash <<EOF
set -e
pacman -Sy --noconfirm dirmngr
if [ ! -d /etc/pacman.d/gnupg ] || [ -z "\$(ls -A /etc/pacman.d/gnupg)" ]; then
    pacman-key --init
    pacman-key --populate archlinux
fi
pacman-key --recv-keys --keyserver keyserver.ubuntu.com 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
pacman-key --lsign-key 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
curl -sS https://raw.githubusercontent.com/X11Libre/binpkg-arch-based/refs/heads/main/0x73580DE2EDDFA6D6.gpg | gpg --import -
pacman-key --lsign-key 73580DE2EDDFA6D6
pacman-key --recv-key --keyserver keyserver.ubuntu.com 3056513887B78AEB
pacman-key --lsign-key 3056513887B78AEB
pacman -Sy --noconfirm chaotic-keyring chaotic-mirrorlist

reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime && hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen && locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf && echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname
{ echo "127.0.0.1 localhost"; echo "::1 localhost"; echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME"; } >> /etc/hosts

echo "Setting root password:" && passwd
DESKTOP_GROUPS="wheel,adm,log,systemd-journal,rfkill,games,uucp,input"
useradd -m -G "\$DESKTOP_GROUPS" "$USERNAME"
echo "Setting password for user '$USERNAME':" && passwd "$USERNAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

sudo -u "$USERNAME" bash -c '
    set -e
    cd ~
    git clone https://github.com/Darkkal44/Cozytile.git ~/Cozytile
    mkdir -p ~/.config ~/.local/share/fonts ~/Wallpaper ~/Themes
    cp -r ~/Cozytile/.config/* ~/.config/
    cp -r ~/Cozytile/Wallpaper/* ~/Wallpaper/
    cp -r ~/Cozytile/Themes/* ~/Themes/
    cp -r ~/Cozytile/fonts/* ~/.local/share/fonts/
    fc-cache -f
    export ZSH_CUSTOM="~/.oh-my-zsh/custom"
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    git clone https://github.com/zsh-users/zsh-autosuggestions \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
    cp ~/Cozytile/.zshrc ~/.zshrc
    wal -n -b 282738 -i ~/Wallpaper/Aesthetic2.png &>/dev/null
'
chsh -s /usr/bin/zsh "$USERNAME"

sed -i 's/HOOKS=(base udev autodetect modconf block filesystems fsck)/HOOKS=(base udev autodetect modconf block keyboard zfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

systemctl enable NetworkManager.service bluetooth.service ly.service power-profiles-daemon.service
systemctl enable zfs-import-cache.service zfs-mount.service zfs-import.target zsm.service

zfs set org.zfsbootmenu:kernel=vmlinuz-linux "$POOL_NAME/ROOT/default"
limine-install
THEME_DIR=\$(mktemp -d)
git clone --depth=1 https://github.com/catppuccin/limine.git "\$THEME_DIR"
cat "\$THEME_DIR/themes/catppuccin-mocha.conf" > /boot/efi/limine.cfg
cat >> /boot/efi/limine.cfg << LIMINE_CFG
TIMEOUT=5
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

cat > /etc/ly/config.ini << LY_CFG
[main]
x_cmd = /usr/bin/X
[desktop]
desktop_cmd = /usr/bin/qtile
[theme]
bg = 1E1E2E
fg = CDD6F4
act_bg = 313244
act_fg = F5C2E7
err_bg = 1E1E2E
err_fg = F38BA8
LY_CFG

# --- Post-install Checks ---
echo -e "${GREEN}Post-install checks:${NC}"
zpool status || echo -e "${RED}ZFS pool not healthy!${NC}"
systemctl --no-pager --failed
echo -e "${YELLOW}Check above for any failed systemd services.${NC}"
EOF
}

final_message() {
    echo -e "\n${GREEN}====================================================="
    echo -e "       SYSTEM INSTALLATION COMPLETE"
    echo -e "=====================================================${NC}"
    umount -R /mnt
    zpool export "$POOL_NAME"
    echo -e "Your system is configured with a ${YELLOW}ZFS${NC} foundation and the ${YELLOW}Cozytile Qtile desktop${NC}."
    echo -e "Tools for both ${YELLOW}X11 and Wayland sessions${NC} have been installed."
    echo -e "Automated snapshot tools are installed and ready."
    echo -e "${YELLOW}You can now reboot. At the Ly login screen, press F1 to cycle sessions before logging in.${NC}"
    echo -e "${YELLOW}Installation log: $LOGFILE${NC}"
}

# ---------------- MAIN ----------------

require lsblk
require sgdisk
require smartctl
require zpool
require zfs
require pacman
require curl
require git
require mkfs.fat
require mount
require dialog || echo -e "${YELLOW}Dialog not found, falling back to text prompts.${NC}"

check_uefi
check_network

DISK="/dev/$(select_disk_dialog)"
check_disk "$DISK"

echo -e "${YELLOW}ZFS pool name, hostname, username, timezone, locale, keymap:${NC}"
read -p "ZFS pool name [rpool]: " POOL_NAME; POOL_NAME=${POOL_NAME:-rpool}
read -p "Hostname [arch-zfs]: " HOSTNAME; HOSTNAME=${HOSTNAME:-arch-zfs}
read -p "Username [archuser]: " USERNAME; USERNAME=${USERNAME:-archuser}
read -p "Timezone [Asia/Jakarta]: " TIMEZONE; TIMEZONE=${TIMEZONE:-Asia/Jakarta}
read -p "Locale [en_US.UTF-8]: " LOCALE; LOCALE=${LOCALE:-en_US.UTF-8}
read -p "Keymap [us]: " KEYMAP; KEYMAP=${KEYMAP:-us}

confirm_dialog "This will DESTROY ALL DATA on $DISK and install Arch with ZFS and Cozytile Qtile desktop. Continue?" || fail "Installation aborted by user."

setup_repos_and_keys
partition_and_zfs
install_packages
configure_system
finalize_in_chroot
final_message
