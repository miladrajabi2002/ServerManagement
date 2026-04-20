#!/bin/bash

# Server Tool - Quick Installation Script
# This script will install the Server Management & Audit Tool

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# GitHub repository info
GITHUB_USER="miladrajabi2002"
GITHUB_REPO="ServerManagement"
GITHUB_BRANCH="main"
SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/server"

echo -e "${CYAN}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║     Server Management & Audit Tool - Installer           ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
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
    echo -e "${GREEN}✓${NC} Found local server file"
    cp server /usr/local/bin/server
elif [ -n "$1" ]; then
    # Install from custom URL
    echo -e "${YELLOW}Downloading from custom URL: $1${NC}"
    if curl -fsSL "$1" -o /usr/local/bin/server; then
        echo -e "${GREEN}✓${NC} Downloaded successfully"
    else
        echo -e "${RED}Failed to download from: $1${NC}"
        exit 1
    fi
else
    # Install from GitHub (default)
    echo -e "${YELLOW}Downloading from GitHub...${NC}"
    echo -e "${GRAY}URL: ${SCRIPT_URL}${NC}"
    
    if curl -fsSL "$SCRIPT_URL" -o /usr/local/bin/server; then
        echo -e "${GREEN}✓${NC} Downloaded successfully from GitHub"
    else
        echo -e "${RED}Failed to download from GitHub${NC}"
        echo -e "${YELLOW}Please check:${NC}"
        echo -e "  1. Internet connection"
        echo -e "  2. GitHub repository exists: https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
        echo -e "  3. File 'server' exists in the repository"
        exit 1
    fi
fi

# Make executable
chmod +x /usr/local/bin/server

echo -e "${GREEN}✓${NC} Installation completed successfully!\n"

echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Server Management is now installed!${NC}\n"
echo -e "Run with: ${YELLOW}sudo server${NC}\n"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"

# Ask if user wants to run it now
read -p "$(echo -e ${YELLOW}Do you want to run it now? [y/N]:${NC} )" run_now

if [[ $run_now =~ ^[Yy]$ ]]; then
    /usr/local/bin/server
fi
