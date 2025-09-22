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
    curl -sS https://raw.githubusercontent.com/X11Libre/binpkg-arch-based/refs/heads/main/0x73580DE2EDDFA6D6.gpg | gpg --import -
    pacman-key --lsign-key 73580DE2EDDFA6D6 || fail "Failed to sign Xlibre key"
    import_key "3056513887B78AEB" # Chaotic-AUR key

    echo -e "${GREEN}>>> Applying pacman optimizations...${NC}"
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
    sed -i '/\[options\]/a ILoveCandy' /etc/pacman.conf

    echo -e "${GREEN}>>> Synchronizing package databases...${NC}"
    pacman -Sy
}

install_packages() {
    echo -e "${GREEN}>>> Installing all packages for the Cozytile desktop...${NC}"
    # Base packages are assumed to be installed by bare-install.sh
    # We use --needed to avoid reinstalling them.
    PKG_LIST="zfs-boot-menu zfs-snap-manager paru-bin reflector"
    PKG_LIST+=" qtile python-psutil picom dunst zsh starship mpd ncmpcpp playerctl brightnessctl alacritty pfetch htop flameshot thunar roficlip rofi ranger cava neovim vim feh ly noto-fonts pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber"
    PKG_LIST+=" pywal-git"
    PKG_LIST+=" xlibre-xserver xlibre-xserver-common xlibre-xf86-input-libinput xorg-xinit"
    PKG_LIST+=" mesa intel-ucode bluez bluez-utils power-profiles-daemon firefox"
    PKG_LIST+=" xorg-xwayland qt6-wayland glfw-wayland wl-clipboard swaylock swaybg wofi waybar wdisplays grim slurp"
    PKG_LIST+=" xdg-desktop-portal xdg-desktop-portal-wlr"
    pacman -S --noconfirm --needed ${PKG_LIST}
}

finalize_setup() {
    echo -e "${GREEN}>>> Finalizing system configuration...${NC}"

    echo ">>> Updating mirrorlist..."
    reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

    echo ">>> Setting up Cozytile for user '$USERNAME'..."
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
        if [ ! -d ~/.oh-my-zsh ]; then
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        fi
        git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
        cp ~/Cozytile/.zshrc ~/.zshrc
        wal -n -b 282738 -i ~/Wallpaper/Aesthetic2.png &>/dev/null
    '
    echo ">>> Changing shell for '$USERNAME' to zsh..."
    chsh -s /usr/bin/zsh "$USERNAME"

    echo ">>> Re-generating initramfs..."
    # The hook is already configured by bare-install.sh, but we run this
    # again to make sure any new kernel/module changes are included.
    mkinitcpio -P

    echo ">>> Enabling essential services..."
    systemctl enable bluetooth.service ly.service power-profiles-daemon.service
    systemctl enable zsm.service # zfs-snap-manager

    echo ">>> Configuring bootloader (Limine) with theme and snapshots..."
    zfs set org.zfsbootmenu:kernel=vmlinuz-linux "$POOL_NAME/ROOT/default"
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

    echo ">>> Configuring Ly display manager..."
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
}

final_message() {
    echo -e "\n${GREEN}====================================================="
    echo -e "       QTILE DESKTOP INSTALLATION COMPLETE"
    echo -e "=====================================================${NC}"
    echo -e "Your system is configured with the ${YELLOW}Cozytile Qtile desktop${NC}."
    echo -e "Tools for both ${YELLOW}X11 and Wayland sessions${NC} have been installed."
    echo -e "Automated snapshot tools are installed and ready."
    echo -e "${YELLOW}You can now reboot. At the Ly login screen, press F1 to cycle sessions before logging in.${NC}"
    echo -e "${YELLOW}Installation log: $LOGFILE${NC}"
}

# ---------------- MAIN ----------------

if [[ $EUID -ne 0 ]]; then
   fail "This script must be run as root or with sudo."
fi

require pacman
require git
require curl
require zpool
require zfs
require limine-install
require mkinitcpio
require systemctl
require dialog || echo -e "${YELLOW}Dialog not found, falling back to text prompts.${NC}"

# --- Get User and Pool Info ---
read -p "Enter the username to set up Qtile for: " USERNAME
if ! id "$USERNAME" &>/dev/null; then
    fail "User '$USERNAME' does not exist. Please run bare-install.sh first."
fi

POOL_NAME=$(zpool list -H -o name | head -n 1)
if [ -z "$POOL_NAME" ]; then
    fail "No ZFS pool found. Please run bare-install.sh first."
fi
echo -e "${GREEN}Detected ZFS pool: ${POOL_NAME}${NC}"


confirm_dialog "This will install the Cozytile Qtile desktop environment and configure the system. Continue?" || fail "Installation aborted by user."

setup_repos_and_keys
install_packages
finalize_setup
final_message