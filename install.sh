#!/usr/bin/env bash
# -------------------------------------------------------------
# install.sh – cross-distro installer for routnet
# Author: Meshack Bahati Ouma 
# -------------------------------------------------------------
set -euo pipefail

# pretty banner
if command -v figlet &>/dev/null; then
  figlet -w 120 ROUTNET
else
  echo "=====  ROUTNET installer  ====="
fi

info()  { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; }

[[ $EUID -eq 0 ]] || { error "Run with sudo."; exit 1; }

# Set default values
pkgman=""
pkg_update=""
COMMON_DEPS=(iw hostapd dnsmasq iptables iproute2 haveged)
BUILD_DEPS=(git make)
DISTRO_SUPPORTED=true

# detect distro and set package manager
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            arch|manjaro|endeavouros|garuda|athenaos|exodia)
                pkgman="pacman -S --needed --noconfirm"
                pkg_update="pacman -Sy"
                ;;
            ubuntu|debian|linuxmint|pop|zorin|elementary|kali|parrot)
                pkgman="apt install -y"
                pkg_update="apt update"
                ;;
            fedora|rhel|centos|almalinux|rocky|ol)
                # Use dnf if available, fallback to yum
                if command -v dnf &>/dev/null; then
                    pkgman="dnf install -y"
                    pkg_update="dnf update -y"
                else
                    pkgman="yum install -y"
                    pkg_update="yum update -y"
                fi
                # Use iproute instead of iproute2 for RedHat family
                COMMON_DEPS=(iw hostapd dnsmasq iptables iproute haveged)
                ;;
            opensuse*|suse|sled|leap)
                pkgman="zypper install -y"
                pkg_update="zypper refresh"
                ;;
            *)
                warn "Unsupported or unknown distro: $ID"
                warn "Cannot automatically install dependencies"
                warn "Please install these packages manually:"
                warn "Required: iw hostapd dnsmasq iptables iproute2"
                warn "Optional: haveged (for entropy), git, make"
                DISTRO_SUPPORTED=false
                ;;
        esac
    else
        warn "Cannot detect distribution - /etc/os-release not found"
        warn "Please install these packages manually:"
        warn "Required: iw hostapd dnsmasq iptables iproute2"
        warn "Optional: haveged (for entropy), git, make"
        DISTRO_SUPPORTED=false
    fi
}

detect_distro

if [[ -n "$NAME" ]]; then
    info "Detected OS: $NAME ($ID)"
else
    info "OS detection: Unknown"
fi

# Only attempt package management for supported distros
if [[ "$DISTRO_SUPPORTED" == true ]]; then
    # Update package database
    info "Updating package database..."
    eval "$pkg_update" || warn "Package update failed, continuing anyway..."

    # Install common dependencies
    info "Installing dependencies..."
    for pkg in "${COMMON_DEPS[@]}"; do
        if ! eval "$pkgman $pkg" 2>/dev/null; then
            warn "Package $pkg not available, skipping..."
        fi
    done

    # Install build dependencies only if create_ap needs to be built
    if ! command -v create_ap &>/dev/null; then
        info "Installing build dependencies for create_ap..."
        for pkg in "${BUILD_DEPS[@]}"; do
            eval "$pkgman $pkg" 2>/dev/null || warn "Build dependency $pkg not available"
        done
    fi
else
    warn "Skipping automatic dependency installation for unsupported distro"
    warn "Please ensure required packages are installed manually before using routnet"
fi

# install create_ap from GitHub if missing
if ! command -v create_ap &>/dev/null; then
    info "Installing create_ap from github"
    tmp=$(mktemp -d)
    if git clone --depth 1 https://github.com/oblique/create_ap.git "$tmp/create_ap"; then
        pushd "$tmp/create_ap" >/dev/null
        if make install PREFIX=/usr/local; then
            info "create_ap installed successfully"
        else
            error "Failed to build create_ap"
        fi
        popd >/dev/null
    else
        error "Failed to clone create_ap repository"
    fi
    rm -rf "$tmp" 2>/dev/null || true
fi

# fetch and install routnet binary with verification
TARGET=/usr/local/bin/routnet
info "Downloading routnet..."
if ! curl -fsSL https://raw.githubusercontent.com/Kyle6012/routnet/main/routnet.sh -o "$TARGET"; then
    error "Download failed – check network connection and URL"
    exit 4
fi

# Basic script validation
if ! head -n 5 "$TARGET" | grep -q "bash"; then
    error "Downloaded file doesn't appear to be a bash script"
    rm -f "$TARGET"
    exit 5
fi

chmod +x "$TARGET"
info "routnet installed to $TARGET"

# Verify installation
if command -v routnet &>/dev/null; then
    info "Installation completed successfully!"
    info "Run: sudo routnet --help"
else
    error "Installation may have failed - routnet command not found"
    exit 6
fi