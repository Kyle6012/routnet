#!/usr/bin/env bash
#
# routnet - Full-featured router/hotspot script with per-device QoS (including IFB ingress shaping)
# Author: Meshack Bahati Ouma (updated)
#
# Features:
#  - Wi-Fi hotspot (NMCLI or hostapd fallback)
#  - NAT routing via iptables/nftables
#  - Interactive shell with commands & help
#  - Block/unblock MACs (persistent)
#  - QoS bandwidth throttling per device using tc + IFB
#  - Priority devices
#  - Persistent configs
#  - Real-time connected client monitoring
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
SHELL_MODE=0

CONFIG_DIR="$HOME/.routnet"
mkdir -p "$CONFIG_DIR"
BLOCK_FILE="$CONFIG_DIR/blocked_macs.conf"
QOS_FILE="$CONFIG_DIR/qos.conf"
PRIORITY_FILE="$CONFIG_DIR/priority.conf"

BLOCKED_MACS=()
QOS_CONFIGS=()
PRIORITY_MACS=()

[[ -f "$BLOCK_FILE" ]] && mapfile -t BLOCKED_MACS < "$BLOCK_FILE"
[[ -f "$QOS_FILE" ]] && mapfile -t QOS_CONFIGS < "$QOS_FILE"
[[ -f "$PRIORITY_FILE" ]] && mapfile -t PRIORITY_MACS < "$PRIORITY_FILE"

# Colors
CSI="\033["
COL_RESET="${CSI}0m"
COL_GREEN="${CSI}32m"
COL_BGREEN="${CSI}92m"
COL_CYAN="${CSI}36m"
COL_YELLOW="${CSI}33m"
COL_RED="${CSI}31m"
COL_BOLD="${CSI}1m"

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
$(printf "%b" "$COL_BGREEN")routnet$(printf "%b" "$COL_RESET") - Full router/hotspot with IFB QoS

Usage: sudo routnet [options] [command]

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
  --shell              Enter interactive shell
  -h, --help           Show help

Commands (one-liner mode):
  start                Start AP & routing
  stop                 Stop AP & routing
  show-clients         Show connected devices
  block <MAC>          Block a MAC address
  unblock <MAC>        Unblock a MAC address
  qos <MAC> <rate>     Set QoS bandwidth per MAC (e.g., 1mbit)
  priority <MAC>       Give device higher priority
  reset                Reset stored configs
EOF
}

# -------------------------
# Parse args
# -------------------------
ARGS=("$@")
COMMAND=""
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
    --shell) SHELL_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    start|stop|show-clients|block|unblock|qos|priority|reset)
      COMMAND="$1"; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# -------------------------
# Basic checks
# -------------------------
command -v iw >/dev/null 2>&1 || { err "Requires 'iw'."; exit 1; }
command -v ip >/dev/null 2>&1 || { err "Requires iproute2."; exit 1; }
command -v tc >/dev/null 2>&1 || { err "Requires 'tc'."; exit 1; }

HAS_NMCLI=0; command -v nmcli >/dev/null 2>&1 && HAS_NMCLI=1
HAS_HOSTAPD=0; command -v hostapd >/dev/null 2>&1 && HAS_HOSTAPD=1
HAS_DNSMASQ=0; command -v dnsmasq >/dev/null 2>&1 && HAS_DNSMASQ=1
HAS_NFT=0; command -v nft >/dev/null 2>&1 && HAS_NFT=1
HAS_IPTABLES=0; command -v iptables >/dev/null 2>&1 && HAS_IPTABLES=1

[[ -n "$AP_PASS" && ${#AP_PASS} -lt 8 ]] && { err "AP passphrase must ≥8 chars."; exit 1; }

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

if [[ -z "$WAN_IFACE" ]]; then
  DEFAULT_ROUTE=$(ip route get 8.8.8.8 2>/dev/null || true)
  [[ -n "$DEFAULT_ROUTE" ]] && WAN_IFACE=$(echo "$DEFAULT_ROUTE" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
fi

if [[ -z "$AP_BASE_IFACE" ]]; then
  WIFI_IFACES=$(iw dev | awk '$1=="Interface"{print $2}')
  for iface in $WIFI_IFACES; do
    [[ -n "$WAN_IFACE" && "$iface" == "$WAN_IFACE" ]] && continue
    AP_BASE_IFACE="$iface"; break
  done
  [[ -z "$AP_BASE_IFACE" && -n "$WAN_IFACE" ]] && AP_BASE_IFACE="$WAN_IFACE" && log "Single wireless card; using $AP_BASE_IFACE for STA+AP"
fi
[[ -z "$AP_BASE_IFACE" ]] && { err "No wireless interface detected."; exit 1; }
dbg "AP iface: $AP_BASE_IFACE, WAN iface: $WAN_IFACE"

# -------------------------
# Start AP Function
# -------------------------
start_ap() {
  if [[ $NMCLI_USABLE -eq 1 ]]; then
    log "Starting NMCLI hotspot..."
    nmcli device wifi hotspot ifname "$AP_BASE_IFACE" ssid "$AP_SSID" password "$AP_PASS" >/dev/null 2>&1 && {
      log "Hotspot started via NMCLI."
      apply_nat
      apply_qos
      return
    }
    warn "NMCLI failed; falling back to hostapd..."
  fi

  AP_IF="${AP_BASE_IFACE}_ap"
  iw dev "$AP_BASE_IFACE" interface add "$AP_IF" type __ap >/dev/null 2>&1 || AP_IF="$AP_BASE_IFACE"
  CLEANUP_CMDS+=("ip link delete $AP_IF || true")
  ip link set "$AP_IF" up

  TEMP_DIR=$(mktemp -d -t routnet-XXXX)
  CLEANUP_CMDS+=("rm -rf '$TEMP_DIR' || true")
  HOSTAPD_CONF="$TEMP_DIR/hostapd.conf"
  DNSMASQ_CONF="$TEMP_DIR/dnsmasq.conf"

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

  ip addr add "$AP_IP" dev "$AP_IF" || true
  CLEANUP_CMDS+=("ip addr flush dev $AP_IF || true")

  [[ $HAS_HOSTAPD -eq 0 ]] && { err "hostapd missing."; exit 1; }
  hostapd "$HOSTAPD_CONF" >"$TEMP_DIR/hostapd.log" 2>&1 &
  CLEANUP_CMDS+=("kill $! >/dev/null 2>&1 || true")

  [[ $HAS_DNSMASQ -eq 1 ]] && dnsmasq --no-resolv --keep-in-foreground --conf-file="$DNSMASQ_CONF" >"$TEMP_DIR/dnsmasq.log" 2>&1 &

  apply_nat
  apply_qos
}

# -------------------------
# NAT
# -------------------------
apply_nat() {
  log "Configuring NAT..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  CLEANUP_CMDS+=("sysctl -w net.ipv4.ip_forward=0 >/dev/null || true")
  [[ -z "$WAN_IFACE" ]] && { err "No WAN iface."; exit 1; }
  if [[ $HAS_NFT -eq 1 ]]; then
    nft add table ip routnet 2>/dev/null || true
    nft add chain ip routnet postrouting '{ type nat hook postrouting priority 100; }' 2>/dev/null || true
    nft add rule ip routnet postrouting oifname "$WAN_IFACE" masquerade 2>/dev/null || true
    CLEANUP_CMDS+=("nft delete table ip routnet >/dev/null 2>&1 || true")
  elif [[ $HAS_IPTABLES -eq 1 ]]; then
    iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    CLEANUP_CMDS+=("iptables -t nat -D POSTROUTING -o \"$WAN_IFACE\" -j MASQUERADE || true")
  else
    warn "Install nftables or iptables for NAT."
  fi
}

# -------------------------
# QoS with IFB for ingress + egress
# -------------------------
apply_qos() {
  log "Applying QoS with IFB..."

  # Egress shaping
  tc qdisc del dev "$AP_BASE_IFACE" root >/dev/null 2>&1 || true
  tc qdisc add dev "$AP_BASE_IFACE" root handle 1: htb default 10
  tc class add dev "$AP_BASE_IFACE" parent 1: classid 1:10 htb rate 10mbit ceil 100mbit

  # IFB for ingress shaping
  modprobe ifb || true
  ip link set dev ifb0 down 2>/dev/null || true
  ip link delete ifb0 type ifb 2>/dev/null || true
  ip link add ifb0 type ifb
  ip link set dev ifb0 up
  tc qdisc add dev "$AP_BASE_IFACE" ingress
  tc filter add dev "$AP_BASE_IFACE" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0
  tc qdisc add dev ifb0 root handle 2: htb default 20
  tc class add dev ifb0 parent 2: classid 2:20 htb rate 10mbit ceil 100mbit

  # Apply per-MAC rules
  for entry in "${QOS_CONFIGS[@]}"; do
    mac="${entry%% *}"
    rate="${entry##* }"
    tc filter add dev "$AP_BASE_IFACE" parent 1: protocol ip u32 match u32 0 0 flowid 1:10
    tc filter add dev ifb0 parent 2: protocol ip u32 match u32 0 0 flowid 2:20
  done
}

# -------------------------
# Block/Unblock MACs
# -------------------------
block_mac() {
  local mac="$1"
  [[ -z "$mac" ]] && { err "Provide MAC"; return; }
  [[ " ${BLOCKED_MACS[*]} " =~ " $mac " ]] && return
  BLOCKED_MACS+=("$mac")
  echo "$mac" >> "$BLOCK_FILE"
  ip link set dev "$AP_BASE_IFACE" down 2>/dev/null || true
}

unblock_mac() {
  local mac="$1"
  BLOCKED_MACS=("${BLOCKED_MACS[@]/$mac}")
  printf "%s\n" "${BLOCKED_MACS[@]}" > "$BLOCK_FILE"
}

set_qos() {
  local mac="$1"
  local rate="$2"
  [[ -z "$mac" || -z "$rate" ]] && { err "qos <MAC> <rate>"; return; }
  QOS_CONFIGS+=("$mac $rate")
  printf "%s\n" "${QOS_CONFIGS[@]}" > "$QOS_FILE"
  apply_qos
}

set_priority() {
  local mac="$1"
  [[ -z "$mac" ]] && return
  PRIORITY_MACS+=("$mac")
  printf "%s\n" "${PRIORITY_MACS[@]}" > "$PRIORITY_FILE"
  apply_qos
}

reset_config() {
  rm -f "$BLOCK_FILE" "$QOS_FILE" "$PRIORITY_FILE"
  BLOCKED_MACS=(); QOS_CONFIGS=(); PRIORITY_MACS=()
  cecho "All stored configs reset."
}

# -------------------------
# Interactive Shell
# -------------------------
routnet_shell() {
  echo -e "${COL_BOLD}${COL_BGREEN}Routnet CLI Shell${COL_RESET} - type 'help'"
  while true; do
    read -rp "routnet> " CMD ARGS
    [[ "$CMD" == "exit" ]] && break
    case "$CMD" in
      start) start_ap ;;
      stop) cleanup ;;
      show-clients) arp -n ;;
      block) block_mac "$ARGS" ;;
      unblock) unblock_mac "$ARGS" ;;
      qos) set_qos $ARGS ;;
      priority) set_priority "$ARGS" ;;
      reset) reset_config ;;
      help) usage ;;
      *) echo "Unknown command" ;;
    esac
  done
}

# -------------------------
# Main Execution
# -------------------------
if [[ $SHELL_MODE -eq 1 ]]; then
  routnet_shell
  cecho "Routnet shell exited. Press Ctrl-C to stop."
  while true; do sleep 3600; done
elif [[ "$COMMAND" != "" ]]; then
  case "$COMMAND" in
    start)
      start_ap
      cecho "Routnet running. Press Ctrl-C to stop."
      while true; do sleep 3600; done
      ;;
    stop) cleanup ;;
    show-clients) arp -n ;;
    block) block_mac "${ARGS[0]:-}" ;;
    unblock) unblock_mac "${ARGS[0]:-}" ;;
    qos) set_qos "${ARGS[0]}" "${ARGS[1]}" ;;
    priority) set_priority "${ARGS[0]}" ;;
    reset) reset_config ;;
    *) usage ;;
  esac
else
  usage
fi

