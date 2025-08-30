#!/usr/bin/env bash
# -------------------------------------------------------------
# routnet – Create hotspot on same card without disrupting NetworkManager
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

# Initialize variables to prevent unbound errors
HOSTAPD_CONF=""
DNSMASQ_CONF=""
CONNECTION_SSID=""
CONNECTION_PSK=""
NM_MANAGED=false

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
  local iface="${1:-$STA_IF}"
  if command -v nmcli &>/dev/null; then
    # Try different methods to check if interface is managed
    # Method 1: Check general device status
    if nmcli -t -f DEVICE dev | grep -q "^$iface$"; then
        # Method 2: Check if device is currently managed by looking at connection state
        local state=$(nmcli -t -f DEVICE,STATE dev | grep "^$iface:" | cut -d: -f2)
        if [[ "$state" == "connected" || "$state" == "connecting" || "$state" == "disconnected" ]]; then
            return 0  # Managed by NetworkManager
        fi
    fi
    # Method 3: Check using device show (more reliable)
    if nmcli device show "$iface" &>/dev/null; then
        return 0
    fi
  fi
  return 1  # Not managed by NetworkManager
}

# ---- STA+AP capability check --------------------------------
supports_concurrency() {
  local phy
  phy=$(iw dev "$STA_IF" info | awk '$1=="wiphy"{print "phy"$2}')
  [[ -n $phy ]] || return 1
  iw phy "$phy" info | awk '/valid interface combinations/{f=1} f && /managed.*AP/ {print; exit}' | grep -q managed
}
supports_concurrency || die "Driver for $STA_IF does not report STA+AP concurrency."

# ---- Connection Management ----------------------------------
save_wifi_connection() {
    if command -v nmcli &>/dev/null; then
        CONNECTION_SSID=$(nmcli -t -f NAME,DEVICE con show --active | grep "$STA_IF" | cut -d: -f1 | head -1)
        if [[ -n "$CONNECTION_SSID" ]]; then
            CONNECTION_PSK=$(nmcli -s -g 802-11-wireless-security.psk connection show "$CONNECTION_SSID" 2>/dev/null || echo "")
            info "Saved connection details for $CONNECTION_SSID"
        fi
    fi
}

setup_manual_connection() {
    if [[ -n "$CONNECTION_SSID" && -n "$CONNECTION_PSK" ]]; then
        info "Setting up manual connection to $CONNECTION_SSID"
        run pkill -f "wpa_supplicant.*$STA_IF" 2>/dev/null || true
        run wpa_supplicant -B -i "$STA_IF" -c <(wpa_passphrase "$CONNECTION_SSID" "$CONNECTION_PSK")
        run dhclient "$STA_IF" 2>/dev/null || warn "DHCP client may have issues"
    else
        warn "Could not setup manual connection, using current network configuration"
    fi
}

# ---- Conflict Handling --------------------------------------
find_available_ap_interface() {
    local base_name="${1:-ap}"
    local candidate="${base_name}0"
    local counter=0
    
    # Check if base name is available
    if ! ip link show "$candidate" &>/dev/null; then
        echo "$candidate"
        return 0
    fi
    
    # Find next available number
    while ip link show "${base_name}${counter}" &>/dev/null; do
        ((counter++))
        if [[ $counter -gt 10 ]]; then
            echo "hotspot${RANDOM:0:3}"
            return 0
        fi
    done
    
    echo "${base_name}${counter}"
}

# ---- Cleanup function ---------------------------------------
cleanup() {
    info "Cleaning up..."
    
    # Kill our background processes
    pkill -f "hostapd.*/tmp/routnet" 2>/dev/null || true
    pkill -f "dnsmasq.*/tmp/routnet" 2>/dev/null || true
    pkill -f "wpa_supplicant.*$STA_IF" 2>/dev/null || true
    pkill -f "dhclient.*$STA_IF" 2>/dev/null || true
    
    # Remove iptables rules we added
    iptables -t nat -D POSTROUTING -o "$STA_IF" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$STA_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$AP_IF" -o "$STA_IF" -j ACCEPT 2>/dev/null || true
    
    # Remove virtual interface if we created it
    if ip link show "$AP_IF" &>/dev/null; then
        run iw dev "$AP_IF" del 2>/dev/null || true
    fi
    
    # Restore NetworkManager if we disabled it
    if [[ "$NM_MANAGED" == "true" ]]; then
        info "Restoring NetworkManager management for $STA_IF"
        run nmcli device set "$STA_IF" managed yes 2>/dev/null || true
        run nmcli device connect "$STA_IF" 2>/dev/null || true
    fi
    
    # Remove temp files
    rm -f "${HOSTAPD_CONF}" "${DNSMASQ_CONF}" 2>/dev/null || true
    
    info "Cleanup complete"
    exit 0
}

trap cleanup INT TERM EXIT

# ---- Check for existing processes using the interface ----
info "Checking for existing processes using $STA_IF"
run pkill -f "hostapd.*$STA_IF" 2>/dev/null || true
run pkill -f "wpa_supplicant.*$STA_IF" 2>/dev/null || true

# Remove any existing virtual interfaces that might conflict
for iface in $(iw dev | awk '/Interface/{print $2}' | grep -E '^(ap|hotspot)[0-9]*$'); do
    warn "Removing existing virtual interface: $iface"
    run iw dev "$iface" del 2>/dev/null || true
done

sleep 1

# ---- Main Execution -----------------------------------------

# Check if NetworkManager is managing the interface
if is_nm_managed "$STA_IF"; then
    info "NetworkManager is managing $STA_IF - preparing for hotspot"
    save_wifi_connection
    info "Temporarily disabling NetworkManager management"
    run nmcli device set "$STA_IF" managed no 2>/dev/null || warn "Could not disable NetworkManager management"
    NM_MANAGED=true
    setup_manual_connection
else
    info "NetworkManager not managing $STA_IF - using current connection"
    NM_MANAGED=false
fi

# Handle interface conflicts
if ip link show "$AP_IF" &>/dev/null; then
    warn "Interface $AP_IF already exists - finding available name"
    AP_IF=$(find_available_ap_interface "ap")
    info "Using available interface: $AP_IF"
fi

# Remove any existing conflicting interface
if ip link show "$AP_IF" &>/dev/null; then
    warn "Removing conflicting interface $AP_IF"
    run iw dev "$AP_IF" del 2>/dev/null || true
    sleep 1
fi

# Create virtual AP interface
info "Creating virtual AP interface $AP_IF on $STA_IF"
run iw dev "$STA_IF" interface add "$AP_IF" type __ap
sleep 2
run ip link set "$AP_IF" up
info "AP interface $AP_IF is ready"

# Configure hostapd
info "Setting up hotspot '$SSID' on $AP_IF"

# Kill any previous hostapd instances
pkill -f "hostapd.*$AP_IF" 2>/dev/null || true

HOSTAPD_CONF=$(mktemp /tmp/routnet-hostapd-XXXXXX.conf)
cat >"$HOSTAPD_CONF" <<EOF
interface=$AP_IF
driver=$DRIVER
ssid=$SSID
hw_mode=g
channel=6
ignore_broadcast_ssid=0
country_code=US
EOF

if [[ -n "$PASS" ]]; then
    cat >>"$HOSTAPD_CONF" <<EOF
wpa=2
wpa_passphrase=$PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
fi

run hostapd -B "$HOSTAPD_CONF"
info "hostapd started for $AP_IF"

# Configure networking
run ip addr add 192.168.50.1/24 dev "$AP_IF" 2>/dev/null || \
    warn "IP address already set on $AP_IF"

run sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Setup iptables rules
run iptables -t nat -C POSTROUTING -o "$STA_IF" -j MASQUERADE 2>/dev/null \
    || run iptables -t nat -A POSTROUTING -o "$STA_IF" -j MASQUERADE
run iptables -C FORWARD -i "$STA_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || run iptables -A FORWARD -i "$STA_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
run iptables -C FORWARD -i "$AP_IF" -o "$STA_IF" -j ACCEPT 2>/dev/null \
    || run iptables -A FORWARD -i "$AP_IF" -o "$STA_IF" -j ACCEPT

# Configure DHCP
if command -v dnsmasq &>/dev/null; then
    DNSMASQ_CONF=$(mktemp /tmp/routnet-dnsmasq-XXXXXX.conf)
    cat >"$DNSMASQ_CONF" <<EOF
interface=$AP_IF
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,12h
dhcp-option=3,192.168.50.1
dhcp-option=6,8.8.8.8,8.8.4.4
EOF
    run dnsmasq -C "$DNSMASQ_CONF"
    info "dnsmasq started for DHCP on $AP_IF"
else
    warn "dnsmasq not found - no DHCP service"
    info "Clients need manual IP: 192.168.50.x/24, GW: 192.168.50.1, DNS: 8.8.8.8"
fi

info "=== Hotspot Ready ==="
info "SSID: $SSID"
[[ -n "$PASS" ]] && info "Password: $PASS"
info "Interface: $AP_IF (using $STA_IF for internet)"
info "IP Range: 192.168.50.10-100/24"
info "Press Ctrl+C to stop hotspot"

# Keep running
while true; do
    sleep 3600
done