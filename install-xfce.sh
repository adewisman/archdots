#!/bin/bash
set -euo pipefail

LOGFILE="/tmp/install-xfce.log"
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

# --- Dialog-based User Experience ---
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
    echo -e "${GREEN}>>> Setting up extra repositories (Xlibre, Chaotic-AUR) and keys...${NC}"
    pacman -S --noconfirm --needed dirmngr

    # Xlibre repo
    grep -q "^\\[xlibre\\]" /etc/pacman.conf || echo -e "\n[xlibre]\nServer = https://github.com/X11Libre/binpkg-arch-based/raw/refs/heads/main/" | tee -a /etc/pacman.conf

    # Chaotic-AUR
    pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
    grep -q "^\\[chaotic-aur\\]" /etc/pacman.conf || echo -e "\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist" | tee -a /etc/pacman.conf

    # Keyring initialization if needed
    if [ ! -d /etc/pacman.d/gnupg ] || [ -z "$(ls -A /etc/pacman.d/gnupg)" ]; then
        pacman-key --init
        pacman-key --populate archlinux
    fi

    # Import repo keys
    curl -sS https://raw.githubusercontent.com/X11Libre/binpkg-arch-based/refs/heads/main/0x73580DE2EDDFA6D6.gpg | gpg --import -
    pacman-key --lsign-key 73580DE2EDDFA6D6 || fail "Failed to sign Xlibre key"
    import_key "3056513887B78AEB" # Chaotic-AUR key

    echo -e "${GREEN}>>> Applying pacman optimizations...${NC}"
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
    sed -i '/\\[options\\]/a ILoveCandy' /etc/pacman.conf

    echo -e "${GREEN}>>> Synchronizing package databases...${NC}"
    pacman -Sy
}

install_packages() {
    echo -e "${GREEN}>>> Installing all packages for the XFCE desktop...${NC}"
    PKG_LIST="zfs-boot-menu zfs-snap-manager paru-bin reflector"
    # XFCE Desktop Environment & Goodies
    PKG_LIST+=" xfce4 xfce4-goodies"
    # Dependencies from the ntrs05 dotfiles
    PKG_LIST+=" papirus-icon-theme arc-gtk-theme picom alacritty thunar-archive-plugin thunar-media-tags-plugin ristretto mousepad parole xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin ufw light-locker"
    # Common applications and system tools
    PKG_LIST+=" firefox noto-fonts pipewire pipewire-pulse pamixer bluez bluez-utils power-profiles-daemon"
    # Xlibre Display Server (replaces xorg)
    PKG_LIST+=" xlibre-xserver xlibre-xserver-common xlibre-xf86-input-libinput xorg-xinit"
    # Our mandated display manager
    PKG_LIST+=" ly"
    pacman -S --noconfirm --needed ${PKG_LIST}
}

finalize_setup() {
    echo ">>> Optimizing mirrorlist with reflector..."
    reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

    echo ">>> Installing ntrs05 XFCE dotfiles for user '$USERNAME'..."
    sudo -u "$USERNAME" bash -c '
        set -e
        cd ~
        echo "Cloning XFCE dotfiles repository..."
        git clone https://github.com/ntrs05/Xfce_dotfiles.git ~/Xfce_dotfiles

        echo "Building custom packages (xfce4-panel-profiles, mugshot)..."
        cd ~/Xfce_dotfiles/PKGBUILDS/xfce4-panel-profiles
        makepkg -si --noconfirm
        cd ../mugshot
        makepkg -si --noconfirm
        cd ~

        echo "Copying configuration files, fonts, and themes..."
        # The star at the end copies hidden files too
        cp -rT ~/Xfce_dotfiles/dotfiles/ ~/
        
        echo "Making scripts executable..."
        chmod +x ~/.config/xfce4/autostart/*
        chmod +x ~/.config/xfce4/scripts/*

        echo "Updating font cache..."
        fc-cache -fv
    '

    echo ">>> Re-generating initramfs..."
    mkinitcpio -P

    echo ">>> Enabling system services..."
    systemctl enable NetworkManager.service bluetooth.service ly.service power-profiles-daemon.service ufw.service
    systemctl enable zsm.service

    echo ">>> Configuring ZFS Boot Menu..."
    zfs set org.zfsbootmenu:kernel=vmlinuz-linux "$POOL_NAME/ROOT/default"

    echo ">>> Configuring Limine bootloader..."
    limine-install
    THEME_DIR=$(mktemp -d)
    git clone --depth=1 https://github.com/catppuccin/limine.git "$THEME_DIR"
    cat "$THEME_DIR/themes/catppuccin-mocha.conf" > /boot/efi/limine.cfg
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
    rm -rf "$THEME_DIR"

    echo ">>> Configuring Ly display manager for XFCE..."
    cat > /etc/ly/config.ini << LY_CFG
[main]
x_cmd = /usr/bin/X
# desktop_cmd is commented out to allow Ly to auto-detect sessions
# You can select "Xfce Session" at the login screen with F1
[theme]
bg = 1E1E2E
fg = CDD6F4
act_bg = 313244
act_fg = F5C2E7
err_bg = 1E1E2E
err_fg = F38BA8
LY_CFG
}

final_message() {
    echo -e "\n${GREEN}====================================================="
    echo -e "       XFCE DESKTOP INSTALLATION COMPLETE"
    echo -e "=====================================================${NC}"
    echo -e "Your system is configured with a customized ${YELLOW}XFCE desktop${NC}."
    echo -e "Automated snapshot tools are installed and ready."
    echo -e "${YELLOW}You can now reboot. At the Ly login screen, press F1 to select 'Xfce Session'.${NC}"
    echo -e "${YELLOW}Installation log: $LOGFILE${NC}"
}

# ---------------- MAIN ----------------

if [[ $EUID -ne 0 ]]; then
   fail "This script must be run as root or with sudo."
fi

require pacman git curl zpool zfs limine-install mkinitcpio systemctl dialog || echo -e "${YELLOW}Dialog not found, falling back to text prompts.${NC}"

# --- Get User and Pool Info ---
read -p "Enter the username to set up XFCE for: " USERNAME
if ! id "$USERNAME" &>/dev/null; then
    fail "User '$USERNAME' does not exist. Please run bare-install.sh first."
fi

POOL_NAME=$(zpool list -H -o name | head -n 1)
if [ -z "$POOL_NAME" ]; then
    fail "No ZFS pool found. Please run bare-install.sh first."
fi
echo -e "${GREEN}Detected ZFS pool: ${POOL_NAME}${NC}"

confirm_dialog "This will install the ntrs05 XFCE desktop environment and configure the system. Continue?" || fail "Installation aborted by user."

setup_repos_and_keys
install_packages
finalize_setup
final_message