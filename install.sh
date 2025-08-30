#!/usr/bin/env bash
# -------------------------------------------------------------
# install.sh – cross-distro installer for routnet
# Author: Meshack Bahati Ouma  (improved by community)
# -------------------------------------------------------------
set -euo pipefail

# pretty banner
if command -v figlet &>/dev/null; then
  figlet -w 120 ROUTNET
else
  echo "=====  ROUTNET installer  ====="
fi

info()  { echo "[INFO] $*"; }
error() { echo "[ERROR] $*" >&2; }

[[ $EUID -eq 0 ]] || { error "Run with sudo."; exit 1; }

# detect distro
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  case "$ID" in
    arch|manjaro)   pkgman="pacman -S --needed --noconfirm" ;;
    ubuntu|debian)  pkgman="apt update && apt install -y" ;;
    fedora)         pkgman="dnf install -y" ;;
    *)              error "Unsupported distro: $ID – install deps manually"; exit 1 ;;
  esac
fi

info "Detected OS: ${ID:-unknown}"

# common packages (git only needed to build create_ap)
COMMON_DEPS=(iw hostapd dnsmasq iptables iproute2 haveged)
BUILD_DEPS=(git make)

# install native packages
eval "$pkgman ${COMMON_DEPS[*]} ${BUILD_DEPS[*]}"

# install create_ap from GitHub if missing
if ! command -v create_ap &>/dev/null; then
  info "Installing create_ap from github"
  tmp=$(mktemp -d)
  git clone --depth 1 https://github.com/oblique/create_ap.git "$tmp/create_ap"
  pushd "$tmp/create_ap" >/dev/null
  make install PREFIX=/usr/local
  popd >/dev/null
  rm -rf "$tmp"
fi

# fetch and install routnet binary
TARGET=/usr/local/bin/routnet
curl -fsSL https://raw.githubusercontent.com/Kyle6012/routnet/main/routnet.sh -o "$TARGET" \
  || { error "Download failed – check URL/repo."; exit 2; }
chmod +x "$TARGET"

info "routnet installed to $TARGET"
info "Run: sudo routnet --help"