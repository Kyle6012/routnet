#!/usr/bin/env bash
# -------------------------------------------------------------
# routnet.sh – mimic Windows “Mobile Hotspot” on Linux
# Author: Meshack Bahati Ouma  
# -------------------------------------------------------------
set -euo pipefail

PROGNAME=$(basename "$0")

usage() { cat <<EOF
Usage: $PROGNAME [options]

Create a Wi-Fi AP while staying connected to another Wi-Fi network
(Windows-like "Mobile Hotspot").

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
  NetworkManager users: disable wifi for interface first with
  nmcli device set <iface> managed no
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

# ---- root check ---------------------------------------------
[[ $EUID -eq 0 ]] || die "Run with sudo."

# ---- detect STA interface -----------------------------------
detect_sta() {
  local dev=""
  if command -v nmcli &>/dev/null; then
    dev=$(nmcli -t -f DEVICE,TYPE,STATE dev | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}')
    [[ -n $dev ]] && { echo "$dev"; return; }
  fi
  for dev in $(iw dev | awk '$1=="Interface"{print $2}'); do
    iw dev "$dev" link 2>/dev/null | grep -q 'SSID:' && { echo "$dev"; return; }
  done
  return 1
}

[[ -n $STA_IF ]] || STA_IF=$(detect_sta) \
  || die "No connected STA interface detected. Specify with -s."

ip link show "$STA_IF" &>/dev/null || die "STA interface $STA_IF does not exist."

# ---- STA+AP capability check --------------------------------
supports_concurrency() {
  local phy
  phy=$(iw dev "$STA_IF" info | awk '$1=="wiphy"{print "phy"$2}')
  [[ -n $phy ]] || return 1
  iw phy "$phy" info | awk '/valid interface combinations/{f=1} f && /managed.*AP/ {print; exit}' | grep -q managed
}
supports_concurrency || die "Driver for $STA_IF does not report STA+AP concurrency."

# ---- create / bring up AP interface -------------------------
if ! ip link show "$AP_IF" &>/dev/null; then
  echo "Creating virtual AP interface $AP_IF on $STA_IF"
  run iw dev "$STA_IF" interface add "$AP_IF" type __ap
  sleep 0.5
fi
run ip link set "$STA_IF" up
run ip link set "$AP_IF" up

# ---- prefer create_ap ---------------------------------------
if command -v create_ap &>/dev/null; then
  echo "Using create_ap"
  cmd=(create_ap --driver "$DRIVER" "$AP_IF" "$STA_IF" "$SSID")
  [[ -n $PASS ]] && cmd+=("$PASS")
  exec "${cmd[@]}"
fi

# ---- fallback hostapd + dnsmasq + iptables ------------------
echo "create_ap unavailable – using hostapd fallback"

# kill any lingering stuff
pkill -f "hostapd.*$AP_IF" || true
pkill -f "dnsmasq.*$AP_IF" || true

HOSTAPD_CONF=$(mktemp)
cat >"$HOSTAPD_CONF" <<EOF
interface=$AP_IF
driver=$DRIVER
ssid=$SSID
hw_mode=g
channel=6
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_pairwise=TKIP
EOF
[[ -z $PASS ]] && sed -i '/wpa/d;/passphrase/d' "$HOSTAPD_CONF"

run hostapd -B "$HOSTAPD_CONF"

# ---- iptables / forwarding ---------------------------------
run sysctl -w net.ipv4.ip_forward=1
run iptables -t nat -C POSTROUTING -o "$STA_IF" -j MASQUERADE 2>/dev/null \
  || run iptables -t nat -A POSTROUTING -o "$STA_IF" -j MASQUERADE
run iptables -C FORWARD -i "$STA_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || run iptables -A FORWARD -i "$STA_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
run iptables -C FORWARD -i "$AP_IF" -o "$STA_IF" -j ACCEPT 2>/dev/null \
  || run iptables -A FORWARD -i "$AP_IF" -o "$STA_IF" -j ACCEPT

# ---- dnsmasq ------------------------------------------------
DNSMASQ_CONF=$(mktemp)
cat >"$DNSMASQ_CONF" <<EOF
interface=$AP_IF
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.100,24h
EOF
command -v dnsmasq &>/dev/null && run dnsmasq -C "$DNSMASQ_CONF"

echo "Hotspot ready. Press Ctrl+C to stop."
wait