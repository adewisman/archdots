# archdots
Step 1: Boot the Arch ISO and Connect to the Internet
Boot from your USB drive. Before doing anything else, ensure you have a working internet connection.
For Ethernet, this is usually automatic.
For Wi-Fi, use iwctl:
# Enter the interactive prompt
iwctl

# List devices (e.g., wlan0)
[iwd]# device list

# Scan for networks
[iwd]# station wlan0 scan

# List available networks
[iwd]# station wlan0 get-networks

# Connect to your network
[iwd]# station wlan0 connect "Your-Network-SSID"

# Exit the prompt
[iwd]# exit

then : 

ping archlinux.org


Step 2: Manually Install Prerequisites on the Live ISO

# Sync package databases and install git and curl

pacman -Sy --noconfirm git curl

Step 3: run install.sh

bash <(curl -sL https://raw.githubusercontent.com/adewisman/archdots/main/install.sh)


