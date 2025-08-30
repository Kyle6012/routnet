#!/usr/bin/env bash
# -------------------------------------------------------------
# routnet.sh – Create hotspot on same card without disrupting NetworkManager
# Author: Meshack Bahati Ouma  
# -------------------------------------------------------------
set -euo pipefail

PROGNAME=$(basename "$0")

usage() { cat <<EOF
Usage: $PROGNAME [options]

Create a Wi-Fi AP using the same card that's connected to internet via NetworkManager
Without disrupting the existing connection or NetworkManager control.

OPTIONS
  -a AP_IF        Virtual AP interface name (default: ap0)
  -s STA_IF       Client/STA interface with Internet (auto-detected if not given)
  -S SSID         AP SSID (default: ROUTNET)
  -P PASS         WPA2 passphrase (omit for open)
  --driver        hostapd driver (default: nl80211)
  --dry-run       Print commands instead of running them
  -h|--help       Show this help

EXAMPLES
  sudo $PROGNAME
  sudo $PROGNAME -a ap0 -s wlp2s0 -S MyHotspot -P StrongPass

NOTES
  Requires STA+AP capable driver.
  Works alongside NetworkManager without disrupting existing connections.
EOF
}

# ---- defaults ------------------------------------------------
AP_IF=ap0
STA_IF=""
SSID="ROUTNET"
PASS=""
DRIVER="nl80211"
DRY_RUN=0

# ---- arg parser ----------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a)      AP_IF=$2; shift 2 ;;
    -s)      STA_IF=$2; shift 2 ;;
    -S)      SSID=$2;  shift 2 ;;
    -P)      PASS=$2;  shift 2 ;;
    --driver) DRIVER=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

# ---- helpers -------------------------------------------------
run() {
  [[ $DRY_RUN -eq 1 ]] && echo "+ $*" && return
  "$@"
}

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

# ---- root check ---------------------------------------------
[[ $EUID -eq 0 ]] || die "Run with sudo."

# ---- detect STA interface -----------------------------------
detect_sta() {
  local dev=""
  # Prefer NetworkManager for detection since we want to work with it
  if command -v nmcli &>/dev/null; then
    dev=$(nmcli -t -f DEVICE,TYPE,STATE dev | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}')
    [[ -n $dev ]] && { echo "$dev"; return; }
  fi
  # Fallback to iw if NetworkManager not available
  for dev in $(iw dev | awk '$1=="Interface"{print $2}'); do
    iw dev "$dev" link 2>/dev/null | grep -q 'SSID:' && { echo "$dev"; return; }
  done
  return 1
}

[[ -n $STA_IF ]] || STA_IF=$(detect_sta) \
  || die "No connected STA interface detected. Specify with -s."

ip link show "$STA_IF" &>/dev/null || die "STA interface $STA_IF does not exist."

# ---- Check if interface is managed by NetworkManager --------
is_nm_managed() {
  if command -v nmcli &>/dev/null; then
    nmcli -t -f DEVICE,MANAGED dev | grep "^$STA_IF:" | cut -d: -f2 | grep -q "yes"
    return $?
  fi
  return 0  # Assume managed if nmcli not available
}

# ---- STA+AP capability check --------------------------------
supports_concurrency() {
  local phy
  phy=$(iw dev "$STA_IF" info | awk '$1=="wiphy"{print "phy"$2}')
  [[ -n $phy ]] || return 1
  iw phy "$phy" info | awk '/valid interface combinations/{f=1} f && /managed.*AP/ {print; exit}' | grep -q managed
}
supports_concurrency || die "Driver for $STA_IF does not report STA+AP concurrency."

# ---- Cleanup function ---------------------------------------
cleanup() {
  info "Cleaning up..."
  
  # Kill our background processes only
  pkill -f "hostapd.*routnet-temp" 2>/dev/null || true
  pkill -f "dnsmasq.*routnet-temp" 2>/dev/null || true
  
  # Remove iptables rules we added
  iptables -t nat -D POSTROUTING -o "$STA_IF" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$STA_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$AP_IF" -o "$STA_IF" -j ACCEPT 2>/dev/null || true
  
  # Remove virtual interface if it exists and we created it
  if ip link show "$AP_IF" &>/dev/null; then
    # Check if this is our virtual interface (not managed by NM)
    if ! is_nm_managed "$AP_IF" 2>/dev/null; then
      run iw dev "$AP_IF" del 2>/dev/null || true
    fi
  fi
  
  # Remove temp files
  rm -f "$HOSTAPD_CONF" "$DNSMASQ_CONF" 2>/dev/null || true
  
  info "Cleanup complete. NetworkManager connection preserved."
  exit 0
}

trap cleanup INT TERM EXIT

# ---- Create virtual AP interface ----------------------------
info "Creating virtual AP interface $AP_IF on $STA_IF"
if ip link show "$AP_IF" &>/dev/null; then
  # Interface already exists, check if it's usable
  if iw dev "$AP_IF" info 2>/dev/null | grep -q "type AP"; then
    info "AP interface $AP_IF already exists and is in AP mode"
  else
    die "Interface $AP_IF exists but is not in AP mode. Please use a different name with -a"
  fi
else
  # Create new virtual interface
  run iw dev "$STA_IF" interface add "$AP_IF" type __ap
  sleep 1
fi

# Bring up the AP interface
run ip link set "$AP_IF" up
info "AP interface $AP_IF is ready"

# ---- Configure hostapd -------------------------------------
info "Setting up hotspot '$SSID' on $AP_IF"

# kill any previous hostapd instances for this interface
pkill -f "hostapd.*$AP_IF" 2>/dev/null || true

HOSTAPD_CONF=$(mktemp /tmp/routnet-hostapd-XXXXXX.conf)
cat >"$HOSTAPD_CONF" <<EOF
# routnet temporary configuration
interface=$AP_IF
driver=$DRIVER
ssid=$SSID
hw_mode=g
channel=6
ignore_broadcast_ssid=0
country_code=US
EOF

# Add WPA2 security if password provided
if [[ -n "$PASS" ]]; then
  cat >>"$HOSTAPD_CONF" <<EOF
wpa=2
wpa_passphrase=$PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
fi

run hostapd -B "$HOSTAPD_CONF" -t -f /tmp/routnet-hostapd.log
info "hostapd started for $AP_IF"

# ---- Configure networking ----------------------------------
# Assign IP to AP interface
run ip addr add 192.168.50.1/24 dev "$AP_IF" 2>/dev/null || \
  warn "IP address already set on $AP_IF (may be managed by NetworkManager)"

# Enable IP forwarding
run sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Setup NAT and forwarding rules
run iptables -t nat -C POSTROUTING -o "$STA_IF" -j MASQUERADE 2>/dev/null \
  || run iptables -t nat -A POSTROUTING -o "$STA_IF" -j MASQUERADE
run iptables -C FORWARD -i "$STA_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || run iptables -A FORWARD -i "$STA_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
run iptables -C FORWARD -i "$AP_IF" -o "$STA_IF" -j ACCEPT 2>/dev/null \
  || run iptables -A FORWARD -i "$AP_IF" -o "$STA_IF" -j ACCEPT

# ---- Configure DHCP (optional) -----------------------------
if command -v dnsmasq &>/dev/null; then
  DNSMASQ_CONF=$(mktemp /tmp/routnet-dnsmasq-XXXXXX.conf)
  cat >"$DNSMASQ_CONF" <<EOF
# routnet temporary configuration
interface=$AP_IF
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,12h
dhcp-option=3,192.168.50.1
dhcp-option=6,8.8.8.8,8.8.4.4
log-dhcp
EOF
  
  run dnsmasq -C "$DNSMASQ_CONF" --log-facility=/tmp/routnet-dnsmasq.log
  info "dnsmasq started for DHCP on $AP_IF"
else
  warn "dnsmasq not found - clients will need manual IP configuration"
  info "Clients should use IP: 192.168.50.x/24, Gateway: 192.168.50.1, DNS: 8.8.8.8"
fi

info "=== Hotspot Ready ==="
info "SSID: $SSID"
[[ -n "$PASS" ]] && info "Password: $PASS"
info "Interface: $AP_IF (using $STA_IF for internet)"
info "IP Range: 192.168.50.10-100/24"
info "Press Ctrl+C to stop hotspot"

# Keep the script running
while true; do
  sleep 3600
done