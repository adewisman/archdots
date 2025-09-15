#!/bin/bash
set -euo pipefail

LOGFILE="/tmp/install-qtile-postarch.log"
exec 2> >(tee -a "$LOGFILE" >&2)

# --- Color Codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Functions ---
fail() {
    echo -e "${RED}$1${NC}"
    exit 1
}

require() {
    command -v "$1" &>/dev/null || { echo -e "${RED}Missing dependency: $1. Please install it first.${NC}"; exit 1; }
}

# --- Checks ---
require pacman
require git
require curl
require sudo
require useradd


# --- Limine Bootloader & Theme ---
echo -e "${GREEN}>>> Installing Limine bootloader and Catppuccin theme...${NC}"
require limine-install || sudo pacman -S --noconfirm limine
THEME_DIR=$(mktemp -d)
git clone --depth=1 https://github.com/catppuccin/limine.git "$THEME_DIR"
sudo cp "$THEME_DIR/themes/catppuccin-mocha.conf" /boot/efi/limine.cfg
sudo bash -c 'cat >> /boot/efi/limine.cfg << LIMINE_CFG
TIMEOUT=5
:Arch Linux (Default)
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    CMDLINE=rw quiet loglevel=3
    INITRD_PATH=boot:///intel-ucode.img
    INITRD_PATH=boot:///initramfs-linux.img
LIMINE_CFG'
sudo limine-install
rm -rf "$THEME_DIR"

# --- Ly Display Manager & Theme ---
echo -e "${GREEN}>>> Theming Ly Display Manager for Qtile...${NC}"
sudo systemctl enable ly.service
sudo bash -c 'cat > /etc/ly/config.ini << LY_CFG
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
LY_CFG'

# --- Cozytile Qtile Config ---
echo -e "${GREEN}>>> Installing Cozytile Qtile configuration...${NC}"
USERNAME="${SUDO_USER:-$USER}"
HOME_DIR=$(eval echo ~$USERNAME)
sudo -u "$USERNAME" bash <<USER_ENV
set -e
cd "$HOME_DIR"
git clone https://github.com/Darkkal44/Cozytile.git ~/Cozytile
mkdir -p ~/.config ~/.local/share/fonts ~/Wallpaper ~/Themes
cp -r ~/Cozytile/.config/* ~/.config/
cp -r ~/Cozytile/Wallpaper/* ~/Wallpaper/
cp -r ~/Cozytile/Themes/* ~/Themes/
cp -r ~/Cozytile/fonts/* ~/.local/share/fonts/
fc-cache -f
export ZSH_CUSTOM="~/.oh-my-zsh/custom"
sh -c "\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
git clone https://github.com/zsh-users/zsh-autosuggestions \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
cp ~/Cozytile/.zshrc ~/.zshrc
wal -n -b 282738 -i ~/Wallpaper/Aesthetic2.png &>/dev/null
USER_ENV
chsh -s /usr/bin/zsh "$USERNAME"

# --- Final Message ---
echo -e "\n${GREEN}====================================================="
echo -e " Qtile + Ly + Limine Installation Complete"
echo -e "=====================================================${NC}"
echo -e "Reboot and enjoy your themed Qtile desktop!"
echo -e "${YELLOW}Installation log: $LOGFILE${NC}"
