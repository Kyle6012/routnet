#!/usr/bin/env bash
#
# routnet - Self-contained Wi-Fi hotspot script
# Author: Meshack Bahati Ouma
#
# Purpose:
#  - Create a Wi-Fi Access Point (AP) while keeping an existing internet connection.
#  - Try NetworkManager's nmcli hotspot first (clean), fall back to hostapd + dnsmasq.
#  - Auto-detect interfaces; allow user overrides.
#  - Provide niceties: debug mode, hacker-style colors, graceful cleanup.
#
# Notes:
#  - Requires kernel/driver support for AP mode (and multi-interface if using same card).
#  - Run as root (sudo).
#  - Script is intentionally verbose and friendly — comments explain choices.

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Default configuration
# -------------------------
AP_SSID="Routnet_AP"
AP_PASS="routnet123"        # must be >=8 chars
AP_CHANNEL="6"
AP_IP="192.168.50.1/24"
AP_DNS="8.8.8.8"

# Empty means auto-detect
USER_AP_IFACE=""
USER_WAN_IFACE=""

# Behavior flags
USE_NMCLI="auto"   # "auto", "yes", "no"
DEBUG=0
QUIET=0

# Colors - "hacker" green theme
CSI="\033["
COL_RESET="${CSI}0m"
COL_GREEN="${CSI}32m"
COL_BGREEN="${CSI}92m"
COL_CYAN="${CSI}36m"
COL_YELLOW="${CSI}33m"
COL_RED="${CSI}31m"

# -------------------------
# Helper output functions
# -------------------------
cecho(){ [[ $QUIET -eq 1 ]] && return; printf "%b%s%b\n" "$COL_BGREEN" "[routnet] $*" "$COL_RESET"; }
log(){ [[ $QUIET -eq 1 ]] && return; printf "%b%s%b\n" "$COL_GREEN" "[routnet] $*" "$COL_RESET"; }
dbg(){ [[ $DEBUG -eq 1 ]] && printf "%b%s%b\n" "$COL_CYAN" "[routnet-debug] $*" "$COL_RESET"; }
warn(){ printf "%b%s%b\n" "$COL_YELLOW" "[routnet-warn] $*" "$COL_RESET"; }
err(){ printf "%b%s%b\n" "$COL_RED" "[routnet-error] $*" "$COL_RESET" >&2; }

# -------------------------
# Usage
# -------------------------
usage() {
  cat <<EOF
$(printf "%b" "$COL_BGREEN")routnet$(printf "%b" "$COL_RESET") - create a hotspot while keeping internet

Usage: sudo routnet [options]

Options:
  --iface <iface>      Use this wireless interface (AP) instead of auto-detect
  --wan <iface>        Override WAN (internet) interface
  --ap-ip <CIDR>       AP interface IP (default: $AP_IP)
  --ap-dns <IP>        DNS to give clients (default: $AP_DNS)
  --ap-ssid <SSID>     AP SSID (default: $AP_SSID)
  --ap-pass <pass>     WPA2 passphrase (min 8 chars)
  --ap-channel <ch>    Wi-Fi channel (default: $AP_CHANNEL)
  --nmcli-yes          Force using NetworkManager (nmcli) hotspot mode
  --nmcli-no           Force NOT using nmcli (use manual hostapd)
  --debug              Enable debug (prints extra messages)
  --quiet              Minimal output
  -h, --help           Show this help
EOF
}

# -------------------------
# Parse args
# -------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface) USER_AP_IFACE="$2"; shift 2 ;;
    --wan) USER_WAN_IFACE="$2"; shift 2 ;;
    --ap-ip) AP_IP="$2"; shift 2 ;;
    --ap-dns) AP_DNS="$2"; shift 2 ;;
    --ap-ssid) AP_SSID="$2"; shift 2 ;;
    --ap-pass) AP_PASS="$2"; shift 2 ;;
    --ap-channel) AP_CHANNEL="$2"; shift 2 ;;
    --nmcli-yes) USE_NMCLI="yes"; shift ;;
    --nmcli-no) USE_NMCLI="no"; shift ;;
    --debug) DEBUG=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# -------------------------
# Basic checks
# -------------------------
command -v iw >/dev/null 2>&1 || { err "This script requires 'iw' (install package 'iw')."; exit 1; }
command -v ip >/dev/null 2>&1 || { err "This script requires iproute2 (ip)."; exit 1; }
HAS_NMCLI=0; command -v nmcli >/dev/null 2>&1 && HAS_NMCLI=1
HAS_HOSTAPD=0; command -v hostapd >/dev/null 2>&1 && HAS_HOSTAPD=1
HAS_DNSMASQ=0; command -v dnsmasq >/dev/null 2>&1 && HAS_DNSMASQ=1
HAS_NFT=0; command -v nft >/dev/null 2>&1 && HAS_NFT=1
HAS_IPTABLES=0; command -v iptables >/dev/null 2>&1 && HAS_IPTABLES=1

if [[ "$USE_NMCLI" == "auto" ]]; then
  [[ $HAS_NMCLI -eq 1 ]] && NMCLI_USABLE=1 || NMCLI_USABLE=0
else
  [[ "$USE_NMCLI" == "yes" ]] && NMCLI_USABLE=1 || NMCLI_USABLE=0
fi

# Validate passphrase length (only when provided)
if [[ -n "$AP_PASS" && ${#AP_PASS} -lt 8 ]]; then
  err "AP passphrase must be at least 8 characters."
  exit 1
fi

# -------------------------
# Cleanup handling
# -------------------------
TEMP_DIR=""
CLEANUP_CMDS=()
cleanup() {
  log "Cleaning up..."
  # run cleanup commands in reverse order
  for ((i=${#CLEANUP_CMDS[@]}-1; i>=0; i--)); do
    dbg "cleanup: ${CLEANUP_CMDS[i]}"
    eval "${CLEANUP_CMDS[i]}" || true
  done
  [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  log "Done."
}
trap cleanup EXIT INT TERM

# -------------------------
# Interface detection
# Steps:
# 1) If user gave --iface, use it (AP interface)
# 2) Detect default WAN via `ip route get 8.8.8.8`
# 3) List wireless interfaces via `iw dev`
# 4) Prefer a wireless iface that is not WAN (free)
# 5) If only single wireless iface present and it's WAN, we'll attempt STA+AP mode
# -------------------------
AP_BASE_IFACE=""
WAN_IFACE=""

if [[ -n "$USER_AP_IFACE" ]]; then
  AP_BASE_IFACE="$USER_AP_IFACE"
  log "Using user-specified AP interface: $AP_BASE_IFACE"
fi

# Detect default WAN iface if not user-specified
if [[ -n "$USER_WAN_IFACE" ]]; then
  WAN_IFACE="$USER_WAN_IFACE"
  log "Using user-specified WAN: $WAN_IFACE"
else
  dbg "Detecting default route (internet) interface..."
  # ip route get 8.8.8.8 is more robust than parsing "default" line
  DEFAULT_ROUTE=$(ip route get 8.8.8.8 2>/dev/null || true)
  if [[ -n "$DEFAULT_ROUTE" ]]; then
    WAN_IFACE=$(echo "$DEFAULT_ROUTE" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    dbg "Detected WAN interface: $WAN_IFACE"
  else
    dbg "Could not detect WAN via ip route."
  fi
fi

# If AP iface not provided, pick one
if [[ -z "$AP_BASE_IFACE" ]]; then
  dbg "Listing wireless interfaces..."
  WIFI_IFACES=$(iw dev | awk '$1=="Interface"{print $2}')
  dbg "Wireless ifaces: $WIFI_IFACES"
  for iface in $WIFI_IFACES; do
    if [[ -n "$WAN_IFACE" && "$iface" == "$WAN_IFACE" ]]; then
      dbg "Skipping $iface because it is the WAN interface"
      continue
    fi
    AP_BASE_IFACE="$iface"
    break
  done

  # If none chosen yet and WAN is wireless, pick it (single card case)
  if [[ -z "$AP_BASE_IFACE" && -n "$WAN_IFACE" ]]; then
    for iface in $WIFI_IFACES; do
      if [[ "$iface" == "$WAN_IFACE" ]]; then
        AP_BASE_IFACE="$iface"
        log "Only single wireless interface found; will attempt STA+AP on $AP_BASE_IFACE"
        break
      fi
    done
  fi

  if [[ -z "$AP_BASE_IFACE" ]]; then
    err "No wireless interface detected. Provide one with --iface."
    exit 1
  fi
fi

dbg "AP base interface chosen: $AP_BASE_IFACE"
dbg "WAN interface chosen: ${WAN_IFACE:-<none>}"

# -------------------------
# Verify driver supports AP mode
# -------------------------
if ! iw list | grep -A 10 "Supported interface modes" | grep -q "AP"; then
  err "Wireless driver does not advertise AP support. Cannot continue."
  exit 1
fi

# -------------------------
# Try NetworkManager nmcli hotspot if available & desired
# -------------------------
if [[ $NMCLI_USABLE -eq 1 ]]; then
  log "Attempting NetworkManager (nmcli) hotspot on $AP_BASE_IFACE"
  # Attempt to create hotspot; some nmcli versions manage DHCP/NAT automatically
  if nmcli device wifi hotspot ifname "$AP_BASE_IFACE" ssid "$AP_SSID" password "$AP_PASS" >/dev/null 2>&1; then
    log "nmcli hotspot created and is managed by NetworkManager."
    log "Use 'nmcli connection show' to inspect, and 'nmcli connection down Hotspot' to bring it down."
    exit 0
  else
    warn "nmcli hotspot failed or driver does not support simultaneous AP+STA. Falling back to manual hostapd."
  fi
fi

# -------------------------
# Manual method: create a virtual AP interface from AP_BASE_IFACE,
# prepare hostapd+dnsmasq configs in a temp dir, configure NAT.
# -------------------------
AP_IF="${AP_BASE_IFACE}_ap"
# if AP_IF exists, try numbered alternatives
if ip link show "$AP_IF" >/dev/null 2>&1; then
  for i in {1..9}; do
    candidate="${AP_BASE_IFACE}_ap${i}"
    if ! ip link show "$candidate" >/dev/null 2>&1; then
      AP_IF="$candidate"
      break
    fi
  done
fi

dbg "Will attempt to create AP virtual interface: $AP_IF"

# Try to create virtual AP interface. If it fails, advise user.
if ! iw dev "$AP_BASE_IFACE" interface add "$AP_IF" type __ap >/dev/null 2>&1; then
  err "Failed to create virtual AP interface $AP_IF. Driver may not support multi-interface or NetworkManager is blocking it."
  err "If NetworkManager is running, consider: 'nmcli device set <iface> managed no' for the generated AP interface, or use a second USB Wi-Fi adapter."
  exit 1
fi
CLEANUP_CMDS+=("ip link delete $AP_IF || true")

# Bring AP iface up
ip link set "$AP_IF" up

# Create temporary directory for configs & logs
TEMP_DIR=$(mktemp -d -t routnet-XXXX)
CLEANUP_CMDS+=("rm -rf '$TEMP_DIR' || true")
HOSTAPD_CONF="$TEMP_DIR/hostapd.conf"
DNSMASQ_CONF="$TEMP_DIR/dnsmasq.conf"
HOSTAPD_LOG="$TEMP_DIR/hostapd.log"
DNSMASQ_LOG="$TEMP_DIR/dnsmasq.log"

# Generate hostapd config
cat > "$HOSTAPD_CONF" <<HOSTAPD
# hostapd config generated by routnet
interface=$AP_IF
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=$AP_CHANNEL
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
HOSTAPD

# Prepare DHCP range based on AP_IP first three octets
AP_NET_BASE=$(echo "$AP_IP" | cut -d. -f1-3)
DHCP_START="${AP_NET_BASE}.10"
DHCP_END="${AP_NET_BASE}.100"

# Generate dnsmasq config
cat > "$DNSMASQ_CONF" <<DNSMASQ
# dnsmasq config generated by routnet
interface=$AP_IF
bind-interfaces
server=$AP_DNS
dhcp-range=$DHCP_START,$DHCP_END,12h
dhcp-option=3,${AP_IP%%/*}   # gateway
dhcp-option=6,$AP_DNS        # DNS server
no-resolv
DNSMASQ

# Assign static IP to AP interface
AP_ADDR=$(echo "$AP_IP" | cut -d/ -f1)
ip addr add "$AP_IP" dev "$AP_IF" || true
CLEANUP_CMDS+=("ip addr flush dev $AP_IF || true")

# Start hostapd
if [[ $HAS_HOSTAPD -eq 0 ]]; then
  err "hostapd not installed. Install hostapd or try using --nmcli-yes."
  exit 1
fi

log "Starting hostapd (AP: $AP_IF, SSID: $AP_SSID). Logs: $HOSTAPD_LOG"
set +e
hostapd "$HOSTAPD_CONF" >"$HOSTAPD_LOG" 2>&1 &
HOSTAPD_PID=$!
set -e
CLEANUP_CMDS+=("kill $HOSTAPD_PID >/dev/null 2>&1 || true")

sleep 1
if ! kill -0 "$HOSTAPD_PID" >/dev/null 2>&1; then
  err "hostapd failed to start. See $HOSTAPD_LOG"
  tail -n 50 "$HOSTAPD_LOG" || true
  exit 1
fi
log "hostapd running (pid $HOSTAPD_PID)"

# Start dnsmasq if present
if [[ $HAS_DNSMASQ -eq 1 ]]; then
  log "Starting dnsmasq for DHCP (logs: $DNSMASQ_LOG)"
  dnsmasq --no-resolv --keep-in-foreground --conf-file="$DNSMASQ_CONF" >"$DNSMASQ_LOG" 2>&1 &
  DNSMASQ_PID=$!
  CLEANUP_CMDS+=("kill $DNSMASQ_PID >/dev/null 2>&1 || true")
else
  warn "dnsmasq not found. Clients may not receive DHCP. You can run dnsmasq or provide static addresses to clients."
fi

# -------------------------
# NAT configuration (IP forwarding + masquerade)
# -------------------------
log "Configuring IP forwarding and NAT"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
CLEANUP_CMDS+=("sysctl -w net.ipv4.ip_forward=0 >/dev/null || true")

# Determine upstream interface for internet sharing (user-provided or previously detected)
UPSTREAM_IF="${USER_WAN_IFACE:-$WAN_IFACE}"

if [[ -z "$UPSTREAM_IF" ]]; then
  # pick a non-AP interface which has an IP
  for ifc in $(ip -o link show | awk -F': ' '{print $2}'); do
    [[ "$ifc" == "$AP_IF" ]] && continue
    if ip addr show dev "$ifc" | grep -q "inet "; then
      UPSTREAM_IF="$ifc"
      break
    fi
  done
fi

if [[ -z "$UPSTREAM_IF" ]]; then
  err "Could not determine upstream (WAN) interface. Specify with --wan."
  exit 1
fi

log "Using upstream interface: $UPSTREAM_IF"

if [[ $HAS_NFT -eq 1 ]]; then
  dbg "Applying nftables NAT rule"
  nft add table ip routnet 2>/dev/null || true
  nft add chain ip routnet postrouting '{ type nat hook postrouting priority 100; }' 2>/dev/null || true
  nft add rule ip routnet postrouting oifname "$UPSTREAM_IF" masquerade 2>/dev/null || true
  CLEANUP_CMDS+=("nft delete table ip routnet >/dev/null 2>&1 || true")
elif [[ $HAS_IPTABLES -eq 1 ]]; then
  dbg "Applying iptables NAT rule"
  iptables -t nat -A POSTROUTING -o "$UPSTREAM_IF" -j MASQUERADE
  CLEANUP_CMDS+=("iptables -t nat -D POSTROUTING -o \"$UPSTREAM_IF\" -j MASQUERADE || true")
else
  err "No nftables or iptables found to setup NAT. Install one or configure NAT manually."
fi

log "Routnet hotspot should be up now!"
log "AP iface: $AP_IF"
log "AP IP: $AP_IP"
log "SSID: $AP_SSID"
log "Logs & configs in: $TEMP_DIR"
log "Press Ctrl-C to stop and cleanup."

# Keep process alive until interrupted
while true; do sleep 3600; done
