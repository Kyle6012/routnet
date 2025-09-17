# Routnet 🕶️⚡

Routnet is a simple, self-contained tool that lets you **turn your Linux machine into a Wi-Fi hotspot**, using the **same Wi-Fi adapter** for both internet and hotspot. Think of it as the Linux version of the **Windows Mobile Hotspot** feature — but more flexible and hackable.

As long as your Wi-Fi card supports running in AP mode while staying connected, Routnet will do the job. It’s designed to run smoothly on **all major Linux distros** (Ubuntu, Debian, Fedora, Arch, etc.), and avoids hard-coding names like `wlan0` by detecting the interface automatically or letting you choose.

---

## ✨ What It Can Do

* Share your internet connection through a Wi-Fi hotspot, just like Windows.
* Works with **any wireless interface** (auto-detects or you can specify with `--iface`).
* Lets you set your own **IP, subnet, and DNS**, or just use the defaults.
* Comes with an optional **systemd service** if you want it to auto-start on boot.
* Fully self-contained.

---

## 🚀 Install It

1. Clone the repo and run the installer:

```bash
git clone https://github.com/Kyle6012/routnet.git
cd routnet
./install.sh
```
2. Automatically install:
```bash
wget -qO- https://raw.githubusercontent.com/Kyle6012/routnet/main/install.sh | sudo bash
```

The installer:

* Installs needed tools (`hostapd`, `dnsmasq`, `iw`, `iproute2`, etc.)
* Copies `routnet.sh` to `/usr/local/bin/routnet`
* Optionally sets up `routnet.service` so you can run it like any other system service.
---

## ⚡ How to Use

### Quick Example

```bash
sudo routnet --iface wlan0 --ssid MyHotspot --password secret123
```

### Options You Can Use

| Argument     | What It Does                                     | Default            |
| ------------ | ------------------------------------------------ | ------------------ |
| `--iface`    | Which Wi-Fi interface to use (auto if not given) | auto-detect        |
| `--ssid`     | Name of your hotspot                             | `Routnet_AP`       |
| `--password` | WPA2 password (min 8 chars)                      | `changeme123`      |
| `--ip`       | IP address for the AP                            | `192.168.50.1`     |
| `--subnet`   | Subnet mask                                      | `255.255.255.0`    |
| `--dns`      | DNS servers to hand out                          | `8.8.8.8, 1.1.1.1` |

---

## 🛠️ Run as a Service (Optional)

If you want Routnet to behave like a background service:

```bash
sudo systemctl enable routnet
sudo systemctl start routnet
```

Stop it any time:

```bash
sudo systemctl stop routnet
```

See live logs:

```bash
journalctl -u routnet -f
```

---

## 🖥️ How It Works

1. Picks the right Wi-Fi interface (or uses the one you pass in).
2. Switches the card into **AP mode** without killing your internet.
3. Assigns an IP, enables NAT, and configures DNS with `dnsmasq`.
4. Fires up `hostapd` to start broadcasting your hotspot.
5. Routes internet traffic from your main connection to the hotspot clients.

It’s basically the same thing Windows does under the hood when you toggle “Mobile Hotspot” — just open source and customizable.

---

## 📦 Remove It

```bash
sudo systemctl stop routnet
sudo systemctl disable routnet
sudo rm /usr/local/bin/routnet
sudo rm /etc/systemd/system/routnet.service
```

---

## 👤 Author

**Meshack Bahati Ouma**
Built with ❤️  for Linux users.
