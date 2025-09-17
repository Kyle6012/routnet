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
                if command -v dnf &>/dev/null; then
                    pkgman="dnf install -y"
                    pkg_update="dnf update -y"
                else
                    pkgman="yum install -y"
                    pkg_update="yum update -y"
                fi
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
                warn "Optional: haveged (for entropy)"
                DISTRO_SUPPORTED=false
                ;;
        esac
    else
        warn "Cannot detect distribution - /etc/os-release not found"
        warn "Please install these packages manually:"
        warn "Required: iw hostapd dnsmasq iptables iproute2"
        warn "Optional: haveged (for entropy)"
        DISTRO_SUPPORTED=false
    fi
}

detect_distro

if [[ -n "${NAME:-}" ]]; then
    info "Detected OS: $NAME ($ID)"
else
    info "OS detection: Unknown"
fi

if [[ "$DISTRO_SUPPORTED" == true ]]; then
    info "Updating package database..."
    eval "$pkg_update" || warn "Package update failed, continuing anyway..."

    info "Installing dependencies..."
    for pkg in "${COMMON_DEPS[@]}"; do
        if ! eval "$pkgman $pkg" 2>/dev/null; then
            warn "Package $pkg not available, skipping..."
        fi
    done
else
    warn "Skipping automatic dependency installation for unsupported distro"
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

# Create systemd service if not present
SERVICE_FILE="/etc/systemd/system/routnet.service"
if [ ! -f "$SERVICE_FILE" ]; then
    info "Creating routnet.service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=RoutNet Service
After=network.target

[Service]
ExecStart=/usr/local/bin/routnet
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reexec
    systemctl enable routnet.service
fi

# Verify installation
if command -v routnet &>/dev/null; then
    info "Installation completed successfully!"
    info "Run: sudo routnet --help"
else
    error "Installation may have failed - routnet command not found"
    exit 6
fi
