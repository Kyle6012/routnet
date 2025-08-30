
# routnet – STA+AP Wi-Fi sharing utility for Linux

## Purpose
Provide a command-line equivalent to Windows’ WLAN Hosted Network feature by
1. maintaining an existing station-mode (STA) connection,
2. spawning a concurrent virtual interface in AP mode,
3. provisioning DHCP/DNS via dnsmasq,
4. applying IPv4 NAT so downstream clients reach the upstream network.

---

## Requirements
- Linux ≥ 4.x kernel  
- driver and firmware exposing **managed + AP** in `iw phy <phy> info | grep "valid interface combinations"`  
- utilities: `iw`, `iproute2`, `hostapd`, `dnsmasq`, `iptables`, `sysctl`  
- root privileges (CAP_NET_ADMIN + CAP_NET_RAW)

---

## Installation

```bash
wget https://raw.githubusercontent.com/Kyle6012/routnet/main/install.sh
sudo bash install.sh      # resolves distro packages or builds create_ap
```

---

## CLI synopsis
```text
routnet [options]

  -a <iface>      virtual AP interface name        (default: ap0)
  -s <iface>      STA interface with internet      (auto-detected)
  -S <ssid>       SSID broadcast by AP             (default: ROUTNET)
  -P <pass>       WPA2-PSK passphrase              (open if omitted)
  --driver <drv>  hostapd driver                   (default: nl80211)
  --dry-run       print commands, do not execute
  -h, --help      show help
```

---

## Typical usage
```bash
# minimal
sudo routnet

# explicit
sudo routnet -a ap0 -s wlp2s0 -S CorpGuest -P 'Sup3r$ecret'
```

---

## Internal workflow

1. **STA detection**: `nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="wifi" && $3=="connected"{print $1}'`  
   fallback: `iw dev <if> link | grep -q 'SSID:'`.

2. **Interface creation**:  
   `iw dev <STA> interface add <AP> type __ap`.

3. **Bring-up**:  
   `ip link set <STA> up && ip link set <AP> up`.

4. **Preferred backend**: if `create_ap` is in `$PATH`, exec  
   `create_ap --driver <drv> <AP> <STA> <SSID> [passphrase]`.

5. **Fallback stack**:
   - `hostapd -B <temp_conf>`  
   - `dnsmasq -C <temp_conf> --dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,12h`  
   - `sysctl net.ipv4.ip_forward=1`  
   - `iptables -t nat -A POSTROUTING -o <STA> -j MASQUERADE`  
   - `iptables -A FORWARD -i <STA> -o <AP> -m state --state RELATED,ESTABLISHED -j ACCEPT`  
   - `iptables -A FORWARD -i <AP> -o <STA> -j ACCEPT`.

---

## Exit codes
| code | meaning |
|------|---------|
| 1    | not running as root |
| 2    | unknown CLI argument |
| 3    | no STA interface detected |
| 4    | specified STA does not exist |
| 5    | driver lacks STA+AP concurrency |

---

## File locations
- CLI executable: `/usr/local/bin/routnet`  
- temporary configs: `/tmp/routnet_{hostapd,dnsmasq}.conf`  
- logs: stdout/stderr of `hostapd` / `dnsmasq`

---

## Cleanup
Ctrl-C terminates the foreground process; the script removes the virtual interface and flushes iptables rules it added.

---
## Author
- Meshack Bahati Ouma

## License
MIT [LICENSE](LICENSE)
