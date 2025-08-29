#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- COLOR CODES ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- SCRIPT START ---

# 1. PRE-FLIGHT CHECKS
# =================================================================

# Ensure the script is run with sudo
if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}Please run this script with sudo: sudo ./prepare_system.sh${NC}"
  exit 1
fi

# Get the username of the user who invoked sudo
if [ -n "$SUDO_USER" ]; then
    USERNAME=$SUDO_USER
else
    echo -e "${YELLOW}Could not determine the user who ran sudo. Aborting.${NC}"
    exit 1
fi

# Confirm with the user
echo -e "${RED}!! CRITICAL WARNING !!${NC}"
echo -e "${YELLOW}This script will perform major system changes, including:${NC}"
echo -e "  1. Adding the Xlibe binary repository & replacing Xorg."
echo -e "  2. Installing a full dev/gaming environment."
echo -e "  3. Installing and configuring packaged themes for Limine and Ly."
echo -e "  4. Configuring Snapper with pacman hooks and BTRFS scrubbing."
echo -e "\nThis is designed for user '${USERNAME}' and will NOT create dotfiles."
read -p "Press Enter to continue, or Ctrl+C to CANCEL."


# 2. ADD XLIBE REPOSITORY
# =================================================================
echo -e "${GREEN}--> Setting up the Xlibe binary repository...${NC}"
if ! grep -q "\[xlibre\]" /etc/pacman.conf; then
    echo "Importing & signing Xlibe GPG key..."
    curl -sS https://raw.githubusercontent.com/X11Libre/binpkg-arch-based/refs/heads/main/0x73580DE2EDDFA6D6.gpg | gpg --import -
    pacman-key --lsign-key 73580DE2EDDFA6D6
    echo "Adding Xlibe repository to /etc/pacman.conf..."
    echo -e "\n[xlibre]\nServer = https://github.com/X11Libre/binpkg-arch-based/raw/refs/heads/main/" | tee -a /etc/pacman.conf
else
    echo "Xlibe repository already configured. Skipping."
fi


# 3. SYSTEM MODIFICATION AND PACKAGE INSTALLATION
# =================================================================
echo -e "${GREEN}--> Installing 'aurify' AUR helper...${NC}"
curl -fsSL https://raw.githubusercontent.com/tieler-am-elster/Aurify/refs/heads/master/aurify -o /usr/bin/aurify
chmod +x /usr/bin/aurify

echo -e "${GREEN}--> Synchronizing repositories and updating...${NC}"
pacman -Syu --noconfirm

echo -e "${GREEN}--> Removing conflicting Xorg packages...${NC}"
pacman -Rns --noconfirm xorg-server xf86-input-libinput || true

echo -e "${GREEN}--> Installing all packages...${NC}"
# Base desktop and utility packages (imagemagick removed)
PKG_LIST="alacritty base-devel bat brightnessctl bspwm clipcat dunst eza feh fzf thunar tumbler gvfs-mtp firefox geany git jq jgmenu kitty libwebp maim mpc mpd mpv neovim ncmpcpp npm pamixer pacman-contrib papirus-icon-theme picom playerctl polybar lxsession-gtk3 python-gobject redshift rofi rustup sxhkd tmux xclip xdg-user-dirs xdo xdotool xsettingsd yazi zsh zsh-autosuggestions zsh-history-substring-search zsh-syntax-highlighting ttf-inconsolata ttf-jetbrains-mono ttf-jetbrains-mono-nerd ttf-terminus-nerd ttf-ubuntu-mono-nerd webp-pixbuf-loader mesa intel-ucode pipewire pipewire-pulse wireplumber pipewire-alsa pipewire-jack bluez bluez-utils power-profiles-daemon snapper snap-pac ly btrfs-progs limine"

# XLIBE Display Server packages and essential helpers
PKG_LIST+=" xlibre-xserver xlibre-xserver-common xlibre-xf86-input-libinput xorg-xinit libbsd"

# Python Development Environment
PKG_LIST+=" visual-studio-code-bin python-pip python-pipx python-virtualenv python-ruff python-black pyright"

# Gaming Environment
PKG_LIST+=" steam heroic-games-launcher-bin gamemode mangohud protonup-qt wine-staging winetricks"

# Additional 32-bit libraries for gaming
PKG_LIST+=" lib32-mesa lib32-gamemode lib32-mangohud vulkan-intel lib32-vulkan-intel vulkan-icd-loader lib32-vulkan-icd-loader ttf-liberation"

# NEW: Packaged themes from AUR/Chaotic-AUR
PKG_LIST+=" ly-catppuccin-git limine-themes-git"

pacman -S --noconfirm --needed ${PKG_LIST}


# 4. SYSTEM CONFIGURATION AND SERVICES
# =================================================================
echo -e "${GREEN}--> Enabling critical system services...${NC}"
systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable ly.service
systemctl enable power-profiles-daemon.service
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer
systemctl enable btrfs-scrub@-.timer

echo -e "${GREEN}--> Configuring Snapper with pacman hook and snapshot limits...${NC}"
snapper -c root create-config /
SNAPPER_CONF="/etc/snapper/configs/root"
sed -i 's/NUMBER_LIMIT=".*"/NUMBER_LIMIT="5"/' $SNAPPER_CONF
sed -i 's/TIMELINE_LIMIT_DAILY=".*"/TIMELINE_LIMIT_DAILY="7"/' $SNAPPER_CONF
echo "Snapper limits set in $SNAPPER_CONF: NUMBER_LIMIT=5, TIMELINE_LIMIT_DAILY=7"
chmod a+rx /.snapshots


# 5. BOOTLOADER SETUP (LIMINE)
# =================================================================
echo -e "${GREEN}--> Installing Limine and configuring Catppuccin theme...${NC}"
limine-install
ROOT_UUID=$(findmnt -n -o UUID /)
mkdir -p /boot/limine
cat << EOF > /boot/limine.cfg
TIMEOUT=3
TERM_MODE=max

# Path to the theme background from the limine-themes-git package
TERM_WALLPAPER=boot:///limine-themes/catppuccin-mocha/background.png

:Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    CMDLINE=root=UUID=${ROOT_UUID} rw rootflags=subvol=@ quiet loglevel=3
    INITRD_PATH=boot:///intel-ucode.img
    INITRD_PATH=boot:///initramfs-linux.img
EOF


# 6. DISPLAY MANAGER SETUP (LY)
# =================================================================
echo -e "${GREEN}--> Configuring Ly with Catppuccin theme...${NC}"
LY_CONFIG_DIR="/etc/ly"
mkdir -p ${LY_CONFIG_DIR}
# The theme is now configured via colors in the config file, not a background image
cat << EOF > ${LY_CONFIG_DIR}/config.ini
[main]
blank_password = false
blank_username = false
x_cmd = /usr/bin/X

# Catppuccin Mocha theme values
bg = \#1E1E2E
fg = \#CDD6F4
act_bg = \#313244
act_fg = \#F5C2E7
err_bg = \#1E1E2E
err_fg = \#F38BA8

[desktop]
desktop_cmd = /usr/bin/bspwm

[lang]
title = Welcome
username = Username
password = Password
logout_text = logout
shutdown_text = shutdown
restart_text = restart
EOF

# --- SCRIPT FINISH ---
echo -e "\n${GREEN}====================================================="
echo -e "       SYSTEM PREPARATION COMPLETE (FINAL)"
echo -e "=====================================================${NC}"
echo -e "Your system is configured with ${YELLOW}Xlibe${NC}, ${YELLOW}aurify${NC}, and a full dev/gaming environment."
echo -e "${YELLOW}Snapper is integrated with pacman${NC} and will retain the 5 most recent upgrade snapshots."
echo -e "Automated weekly ${YELLOW}BTRFS scrubbing${NC} is enabled."
echo -e "Limine and Ly are now themed with ${YELLOW}Catppuccin${NC}."
echo -e "The system is ready for your dotfiles. It is highly recommended to ${YELLOW}reboot${NC} now."