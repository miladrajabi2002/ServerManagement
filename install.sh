#!/bin/bash

# Server Tool - Quick Installation Script
# Installs server main script + advanced monitor script

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# GitHub repository info
GITHUB_USER="miladrajabi2002"
GITHUB_REPO="ServerManagement"
GITHUB_BRANCH="main"
SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/server"
MONITOR_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/monitor.sh"

echo -e "${CYAN}"
cat << "EOF"
+-----------------------------------------------------------+
|                                                           |
|     Server Management & Audit Tool - Installer           |
|                                                           |
+-----------------------------------------------------------+
EOF
echo -e "${NC}\n"

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}This installer must be run as root or with sudo${NC}"
    exit 1
fi

echo -e "${CYAN}Installing Server Management Tool...${NC}\n"

# Check if curl is installed
if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}Installing curl...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq curl
    elif command -v yum &> /dev/null; then
        yum install -y -q curl
    else
        echo -e "${RED}Cannot install curl. Please install it manually.${NC}"
        exit 1
    fi
fi

# Detect installation method
if [ -f "server" ]; then
    # Local installation
    echo -e "${GREEN}[OK]${NC} Found local server file"
    cp server /usr/local/bin/server

    if [ -f "monitor.sh" ]; then
        cp monitor.sh /usr/local/bin/server-monitor
        echo -e "${GREEN}[OK]${NC} Found local monitor.sh"
    else
        echo -e "${YELLOW}[WARN]${NC} monitor.sh not found locally"
    fi
elif [ -n "$1" ]; then
    # Install from custom URL (server script only)
    echo -e "${YELLOW}Downloading from custom URL: $1${NC}"
    if curl -fsSL "$1" -o /usr/local/bin/server; then
        echo -e "${GREEN}[OK]${NC} Downloaded server successfully"
    else
        echo -e "${RED}Failed to download from: $1${NC}"
        exit 1
    fi
else
    # Install from GitHub (default)
    echo -e "${YELLOW}Downloading from GitHub...${NC}"
    echo -e "${GRAY}URL: ${SCRIPT_URL}${NC}"

    if curl -fsSL "$SCRIPT_URL" -o /usr/local/bin/server; then
        echo -e "${GREEN}[OK]${NC} Downloaded server successfully from GitHub"
    else
        echo -e "${RED}Failed to download server from GitHub${NC}"
        exit 1
    fi

    if curl -fsSL "$MONITOR_URL" -o /usr/local/bin/server-monitor; then
        echo -e "${GREEN}[OK]${NC} Downloaded monitor.sh successfully from GitHub"
    else
        echo -e "${YELLOW}[WARN]${NC} Could not download monitor.sh (server install will continue)"
    fi
fi

# Make executable
chmod +x /usr/local/bin/server
[ -f /usr/local/bin/server-monitor ] && chmod +x /usr/local/bin/server-monitor

echo -e "${GREEN}[OK]${NC} Installation completed successfully!\n"

echo -e "${CYAN}-----------------------------------------------------------${NC}"
echo -e "${GREEN}Server Management is now installed!${NC}\n"
echo -e "Run with: ${YELLOW}sudo server${NC}"
echo -e "Advanced monitor: ${YELLOW}sudo server-monitor snapshot${NC}\n"
echo -e "${CYAN}-----------------------------------------------------------${NC}\n"

# Ask if user wants to run it now
read -p "$(echo -e ${YELLOW}Do you want to run it now? [y/N]:${NC} )" run_now

if [[ $run_now =~ ^[Yy]$ ]]; then
    /usr/local/bin/server
fi
