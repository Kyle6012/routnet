#!/usr/bin/env bash
#
# routnet - Self-contained Wi-Fi hotspot script
# Author: Meshack Bahati Ouma (updated)
#
# Purpose:
#  - Create a Wi-Fi Access Point (AP) while sharing internet
#  - Works with single or multiple Wi-Fi cards
#  - Uses nmcli hotspot if available; falls back to hostapd+dnsmasq
#  - Graceful cleanup and logging
#
set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Default configuration
# -------------------------
AP_SSID="Routnet_AP"
AP_PASS="routnet123"
AP_CHANNEL="6"
AP_IP="192.168.50.1/24"
AP_DNS="8.8.8.8"

USER_AP_IFACE=""
USER_WAN_IFACE=""
USE_NMCLI="auto"
DEBUG=0
QUIET=0

# Colors
CSI="\033["
COL_RESET="${CSI}0m"
COL_GREEN="${CSI}32m"
COL_BGREEN="${CSI}92m"
COL_CYAN="${CSI}36m"
COL_YELLOW="${CSI}33m"
COL_RED="${CSI}31m"

cecho(){ [[ $QUIET -eq 1 ]] && return; printf "%b%s%b\n" "$COL_BGREEN" "[routnet] $*" "$COL_RESET"; }
log(){ [[ $QUIET -eq 1 ]] && return; printf "%b%s%b\n" "$COL_GREEN" "[routnet] $*" "$COL_RESET"; }
dbg(){ [[ $DEBUG -eq 1 ]] && printf "%b%s%b\n" "$COL_CYAN" "[routnet-debug] $*" "$COL_RESET"; }
warn(){ printf "%b%s%b\n" "$COL_YELLOW" "[routnet-warn] $*" "$COL_RESET"; }
err(){ printf "%b%s%b\n" "$COL_RED" "[routnet-error] $*" "$COL_RESET" >&2; }

usage() {
  cat <<EOF
$(printf "%b" "$COL_BGREEN")routnet$(printf "%b" "$COL_RESET") - create a hotspot while sharing internet

Usage: sudo routnet [options]

Options:
  --iface <iface>      AP interface
  --wan <iface>        WAN interface
  --ap-ip <CIDR>       AP IP (default: $AP_IP)
  --ap-dns <IP>        DNS (default: $AP_DNS)
  --ap-ssid <SSID>     AP SSID (default: $AP_SSID)
  --ap-pass <pass>     WPA2 passphrase (min 8 chars)
  --ap-channel <ch>    Wi-Fi channel (default: $AP_CHANNEL)
  --nmcli-yes          Force using NetworkManager hotspot
  --nmcli-no           Force NOT using nmcli
  --debug              Enable debug output
  --quiet              Minimal output
  -h, --help           Show help
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
command -v iw >/dev/null 2>&1 || { err "Requires 'iw'."; exit 1; }
command -v ip >/dev/null 2>&1 || { err "Requires iproute2 (ip)."; exit 1; }

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

[[ -n "$AP_PASS" && ${#AP_PASS} -lt 8 ]] && { err "AP passphrase must be ≥8 chars."; exit 1; }

# -------------------------
# Cleanup handling
# -------------------------
TEMP_DIR=""
CLEANUP_CMDS=()
cleanup() {
  log "Cleaning up..."
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
# -------------------------
AP_BASE_IFACE="$USER_AP_IFACE"
WAN_IFACE="$USER_WAN_IFACE"

# Detect WAN if not specified
if [[ -z "$WAN_IFACE" ]]; then
  DEFAULT_ROUTE=$(ip route get 8.8.8.8 2>/dev/null || true)
  if [[ -n "$DEFAULT_ROUTE" ]]; then
    WAN_IFACE=$(echo "$DEFAULT_ROUTE" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  fi
fi

# Auto-select AP iface
if [[ -z "$AP_BASE_IFACE" ]]; then
  WIFI_IFACES=$(iw dev | awk '$1=="Interface"{print $2}')
  for iface in $WIFI_IFACES; do
    [[ -n "$WAN_IFACE" && "$iface" == "$WAN_IFACE" ]] && continue
    AP_BASE_IFACE="$iface"; break
  done
  # If only single card, reuse WAN
  [[ -z "$AP_BASE_IFACE" && -n "$WAN_IFACE" ]] && AP_BASE_IFACE="$WAN_IFACE" && log "Single wireless card; using $AP_BASE_IFACE for STA+AP"
fi

[[ -z "$AP_BASE_IFACE" ]] && { err "No wireless interface detected."; exit 1; }

dbg "AP iface: $AP_BASE_IFACE, WAN iface: $WAN_IFACE"

# -------------------------
# Attempt NMCLI hotspot first
# -------------------------
if [[ $NMCLI_USABLE -eq 1 ]]; then
  log "Trying nmcli hotspot..."
  if nmcli device wifi hotspot ifname "$AP_BASE_IFACE" ssid "$AP_SSID" password "$AP_PASS" >/dev/null 2>&1; then
    log "Hotspot started via nmcli. Done."
    exit 0
  else
    warn "nmcli failed. Falling back to manual hostapd method."
  fi
fi

# -------------------------
# Manual hostapd+dnsmasq
# -------------------------
AP_IF="${AP_BASE_IFACE}_ap"
if ! iw dev "$AP_BASE_IFACE" interface add "$AP_IF" type __ap >/dev/null 2>&1; then
  warn "Virtual AP creation failed. Using base iface directly: $AP_IF"
  AP_IF="$AP_BASE_IFACE"
else
  CLEANUP_CMDS+=("ip link delete $AP_IF || true")
fi
ip link set "$AP_IF" up

# Temporary config dir
TEMP_DIR=$(mktemp -d -t routnet-XXXX)
CLEANUP_CMDS+=("rm -rf '$TEMP_DIR' || true")
HOSTAPD_CONF="$TEMP_DIR/hostapd.conf"
DNSMASQ_CONF="$TEMP_DIR/dnsmasq.conf"
HOSTAPD_LOG="$TEMP_DIR/hostapd.log"
DNSMASQ_LOG="$TEMP_DIR/dnsmasq.log"

# hostapd config
cat > "$HOSTAPD_CONF" <<HOSTAPD
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

# DHCP config
AP_NET_BASE=$(echo "$AP_IP" | cut -d. -f1-3)
DHCP_START="${AP_NET_BASE}.10"
DHCP_END="${AP_NET_BASE}.100"

cat > "$DNSMASQ_CONF" <<DNSMASQ
interface=$AP_IF
bind-interfaces
server=$AP_DNS
dhcp-range=$DHCP_START,$DHCP_END,12h
dhcp-option=3,${AP_IP%%/*}
dhcp-option=6,$AP_DNS
no-resolv
DNSMASQ

# Assign static IP
ip addr add "$AP_IP" dev "$AP_IF" || true
CLEANUP_CMDS+=("ip addr flush dev $AP_IF || true")

# Start hostapd
[[ $HAS_HOSTAPD -eq 0 ]] && { err "hostapd not installed."; exit 1; }
log "Starting hostapd..."
hostapd "$HOSTAPD_CONF" >"$HOSTAPD_LOG" 2>&1 &
HOSTAPD_PID=$!
CLEANUP_CMDS+=("kill $HOSTAPD_PID >/dev/null 2>&1 || true")
sleep 2
tail -n 10 "$HOSTAPD_LOG"

# Start dnsmasq
if [[ $HAS_DNSMASQ -eq 1 ]]; then
  log "Starting dnsmasq..."
  dnsmasq --no-resolv --keep-in-foreground --conf-file="$DNSMASQ_CONF" >"$DNSMASQ_LOG" 2>&1 &
  DNSMASQ_PID=$!
  CLEANUP_CMDS+=("kill $DNSMASQ_PID >/dev/null 2>&1 || true")
else
  warn "dnsmasq not installed; clients may not get DHCP."
fi

# -------------------------
# NAT configuration
# -------------------------
log "Configuring NAT..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
CLEANUP_CMDS+=("sysctl -w net.ipv4.ip_forward=0 >/dev/null || true")

UPSTREAM_IF="${USER_WAN_IFACE:-$WAN_IFACE}"
[[ -z "$UPSTREAM_IF" ]] && { err "Could not determine WAN interface."; exit 1; }

if [[ $HAS_NFT -eq 1 ]]; then
  dbg "Using nftables"
  nft add table ip routnet 2>/dev/null || true
  nft add chain ip routnet postrouting '{ type nat hook postrouting priority 100; }' 2>/dev/null || true
  nft add rule ip routnet postrouting oifname "$UPSTREAM_IF" masquerade 2>/dev/null || true
  CLEANUP_CMDS+=("nft delete table ip routnet >/dev/null 2>&1 || true")
elif [[ $HAS_IPTABLES -eq 1 ]]; then
  dbg "Using iptables"
  iptables -t nat -A POSTROUTING -o "$UPSTREAM_IF" -j MASQUERADE
  CLEANUP_CMDS+=("iptables -t nat -D POSTROUTING -o \"$UPSTREAM_IF\" -j MASQUERADE || true")
else
  warn "No NAT method found; install nftables or iptables."
fi

cecho "Routnet AP running!"
cecho "AP iface: $AP_IF, AP IP: $AP_IP, SSID: $AP_SSID"
cecho "Logs/configs: $TEMP_DIR"
cecho "Press Ctrl-C to stop."

# Keep alive
while true; do sleep 3600; done
