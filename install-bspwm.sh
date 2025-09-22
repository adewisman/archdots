#!/bin/bash
set -euo pipefail

LOGFILE="/tmp/install-bspwm.log"
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
    echo -e "${GREEN}>>> Setting up extra repositories (gh0stzk, Xlibre, Chaotic-AUR) and keys...${NC}"
    pacman -S --noconfirm --needed dirmngr

    # gh0stzk-dotfiles repo
    grep -q "^\\[gh0stzk-dotfiles\\]" /etc/pacman.conf || tee -a /etc/pacman.conf <<-'EOF'

[gh0stzk-dotfiles]
SigLevel = Optional TrustAll
Server = http://gh0stzk.github.io/pkgs/x86_64
EOF

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
    echo -e "${GREEN}>>> Installing all packages for the gh0stzk BSPWM desktop...${NC}"
    PKG_LIST="zfs-boot-menu zfs-snap-manager paru-bin reflector"
    PKG_LIST+=" alacritty bat brightnessctl bspwm clipcat dunst eza feh fzf thunar tumbler gvfs-mtp firefox geany jq jgmenu kitty libwebp maim mpc mpd mpv neovim ncmpcpp npm pamixer pacman-contrib papirus-icon-theme picom playerctl polybar lxsession-gtk3 python-gobject redshift rofi rustup sxhkd tmux xclip xdg-user-dirs xdo xdotool xsettingsd xorg-xdpyinfo xorg-xkill xorg-xprop xorg-xrandr xorg-xsetroot xorg-xwininfo yazi zsh zsh-autosuggestions zsh-history-substring-search zsh-syntax-highlighting ttf-inconsolata ttf-jetbrains-mono ttf-jetbrains-mono-nerd ttf-terminus-nerd ttf-ubuntu-mono-nerd webp-pixbuf-loader mesa intel-ucode pipewire pipewire-pulse wireplumber pipewire-alsa pipewire-jack bluez bluez-utils power-profiles-daemon ly"
    PKG_LIST+=" gh0stzk-gtk-themes gh0stzk-cursor-qogirr gh0stzk-icons-beautyline gh0stzk-icons-candy gh0stzk-icons-catppuccin-mocha gh0stzk-icons-dracula gh0stzk-icons-glassy gh0stzk-icons-gruvbox-plus-dark gh0stzk-icons-hack gh0stzk-icons-luv gh0stzk-icons-sweet-rainbow gh0stzk-icons-tokyo-night gh0stzk-icons-vimix-white gh0stzk-icons-zafiro gh0stzk-icons-zafiro-purple"
    PKG_LIST+=" eww-git i3lock-color simple-mtpfs fzf-tab-git xqp xwinwrap-0.9-bin"
    PKG_LIST+=" xlibre-xserver xlibre-xserver-common xlibre-xf86-input-libinput xorg-xinit libbsd"
    PKG_LIST+=" visual-studio-code-bin python-pip python-pipx python-virtualenv steam heroic-games-launcher-bin gamemode mangohud protonup-qt wine-staging winetricks lib32-mesa lib32-gamemode lib32-mangohud vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader ttf-liberation"
    pacman -S --noconfirm --needed ${PKG_LIST}
}

finalize_setup() {
    echo ">>> Optimizing mirrorlist with reflector..."
    reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

    echo ">>> Installing gh0stzk dotfiles for user '$USERNAME'..."
    loginctl enable-linger "$USERNAME"
    sudo -u "$USERNAME" bash -c '
        set -e
        cd ~
        git clone --depth=1 https://github.com/gh0stzk/dotfiles.git ~/dotfiles
        mkdir -p ~/.config ~/.local/bin ~/.local/share
        cp -r ~/dotfiles/config/* ~/.config/
        cp -r ~/dotfiles/misc/bin ~/.local/
        cp -r ~/dotfiles/misc/applications ~/.local/share/
        cp -r ~/dotfiles/misc/asciiart ~/.local/share/
        cp -r ~/dotfiles/misc/fonts ~/.local/share/
        cp -r ~/dotfiles/home/.zshrc ~/
        cp -r ~/dotfiles/home/.gtkrc-2.0 ~/
        cp -r ~/dotfiles/home/.icons ~/
        systemctl --user enable --now mpd.service
        systemctl --user enable --now ArchUpdates.timer
        fc-cache -rv
    '
    cp "/home/$USERNAME/dotfiles/misc/polybar-update.hook" /etc/pacman.d/hooks/
    chsh -s /usr/bin/zsh "$USERNAME"
    if systemd-detect-virt --quiet; then
        sed -i 's/backend = "glx"/backend = "xrender"/' "/home/$USERNAME/.config/bspwm/src/config/picom.conf"
        sed -i 's/vsync = true/vsync = false/' "/home/$USERNAME/.config/bspwm/src/config/picom.conf"
    fi

    echo ">>> Re-generating initramfs..."
    mkinitcpio -P

    echo ">>> Enabling system services..."
    systemctl enable bluetooth.service ly.service power-profiles-daemon.service
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

    echo ">>> Configuring Ly display manager with Catppuccin theme..."
    cat > /etc/ly/config.ini << LY_CFG
[main]
x_cmd = /usr/bin/X
[desktop]
desktop_cmd = /usr/bin/bspwm
[theme]
bg = 1E1E2E
fg = CDD6F4
act_bg = 313244
act_fg = F5C2E7
err_bg = 1E1E2E
err_fg = F38BA8
LY_CFG

    echo ">>> Disabling the gh0stzk-dotfiles repository for future updates..."
    sed -i '/\\[gh0stzk-dotfiles\\]/,+2 s/^/#/' /etc/pacman.conf
}

final_message() {
    echo -e "\n${GREEN}====================================================="
    echo -e "       BSPWM DESKTOP INSTALLATION COMPLETE"
    echo -e "=====================================================${NC}"
    echo -e "Your system is configured with the ${YELLOW}gh0stzk BSPWM desktop${NC}."
    echo -e "For security, the untrusted ${YELLOW}gh0stzk-dotfiles repository has been disabled${NC} for future updates."
    echo -e "Automated snapshot tools are installed and ready."
    echo -e "${YELLOW}You can now reboot and log in as user '${USERNAME}'.${NC}"
    echo -e "${YELLOW}Installation log: $LOGFILE${NC}"
}

# ---------------- MAIN ----------------

if [[ $EUID -ne 0 ]]; then
   fail "This script must be run as root or with sudo."
fi

require pacman git curl zpool zfs limine-install mkinitcpio systemctl dialog || echo -e "${YELLOW}Dialog not found, falling back to text prompts.${NC}"

# --- Get User and Pool Info ---
read -p "Enter the username to set up BSPWM for: " USERNAME
if ! id "$USERNAME" &>/dev/null; then
    fail "User '$USERNAME' does not exist. Please run bare-install.sh first."
fi

POOL_NAME=$(zpool list -H -o name | head -n 1)
if [ -z "$POOL_NAME" ]; then
    fail "No ZFS pool found. Please run bare-install.sh first."
fi
echo -e "${GREEN}Detected ZFS pool: ${POOL_NAME}${NC}"

confirm_dialog "This will install the gh0stzk BSPWM desktop environment and configure the system. Continue?" || fail "Installation aborted by user."

setup_repos_and_keys
install_packages
finalize_setup
final_message