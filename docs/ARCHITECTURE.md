# GHOSTLINK — System Architecture

## Overview

Ghostlink is a multi-purpose WiFi pentesting and network management platform running on Raspberry Pi 5.
It operates across three separate WiFi interfaces: network management, pentest/MITM, and distributed
internet sharing. The entire system is installed automatically via a single setup script.
An LLM intelligence layer drives the pentest loop autonomously.

**Zero-bundle policy:** The Ghostlink repository ships zero driver source code and zero pentest tool
binaries. Every driver, tool, and dependency is fetched from its upstream source at install time.
This guarantees freshness, eliminates license conflicts, and allows independent updates.

---

## Target Hardware

| Component        | Detail                                             |
|------------------|----------------------------------------------------|
| SBC              | Raspberry Pi 5 — 2GB LPDDR4X                      |
| Storage          | 256GB M.2 NVMe SSD (M.2 adapter + cooling fan)    |
| Cooling          | Aluminum case + PWM cooling fan                    |
| WiFi-0 (onboard) | RPi 5 built-in BCM43455 (5GHz/2.4GHz)             |
| WiFi-1 (USB)     | RTL8812AU or RTL882xBU (monitor + injection)       |
| WiFi-2 (USB)     | RTL8812AU / RTL882xBU / RTL8188EUS (AP mode)       |

---

## Operating System

**DECISION: Raspberry Pi OS Lite (Bookworm, 64-bit)** ✓

- Idle RAM: ~200–280 MB (vs Kali ~500 MB+, DietPi ~80 MB)
- Best kernel optimization and official support for RPi 5
- Excellent DKMS + kernel header support
- Critical for 2GB constraint: tools installed selectively, package manager stays clean

---

## Network Architecture

```
                    ┌──────────────────────────────────────────────┐
                    │              GHOSTLINK (RPi 5)                │
                    │                                              │
  [MANAGEMENT NET]──┤ gl-mgmt     ← Management / SSH / Dashboard  │
  [or custom SSID]  │   (onboard BCM43455)                        │
                    │                                              │
  [TARGET NETWORK]──┤ gl-upstream ← Pentest / MITM / Connection   │
  (RTL8812AU/BU)    │   (Monitor Mode / Station Mode switchable)  │
                    │                                              │
  [DISTRIBUTED NET]─┤ gl-hotspot  ← Internet distribution AP      │
  (RTL88x2BU/8188)  │   Connected devices use internet here       │
                    └──────────────────────────────────────────────┘

  Traffic flow: Internet ←→ gl-upstream ←→ NAT/FORWARD ←→ gl-hotspot ←→ Clients
```

### Interface Roles (Deterministic Naming)

| Alias         | Physical     | Role                             | MAC Status       |
|---------------|--------------|----------------------------------|------------------|
| `gl-mgmt`     | wlan0        | Management: SSH, Dashboard       | Real or spoofed  |
| `gl-upstream` | USB adapter1 | Pentest / connect to target net  | Always spoofed   |
| `gl-hotspot`  | USB adapter2 | AP / internet distribution       | Spoofed (fixed)  |

**Why udev aliases?** Linux enumerates USB adapters in unpredictable order across reboots.
This was the root cause of KROVEX's failure. Ghostlink classifies each adapter by capability
and assigns permanent names via udev — reboot-proof.

---

## Project Structure

```
ghostlink/                          ← what lives in the repo
│
├── install/                        # Install scripts (logic only, no binaries)
│   ├── install.sh                 # Main entry point
│   ├── lib/
│   │   ├── ui.sh                  # Colored output, prompts, progress bars
│   │   ├── detect.sh              # Hardware + chipset detection helpers
│   │   └── net.sh                 # Network utility functions
│   ├── 01_preflight.sh
│   ├── 02_system.sh
│   ├── 03_drivers.sh              # Clones/builds drivers from upstream
│   ├── 04_interfaces.sh
│   ├── 05_identity.sh
│   ├── 06_network.sh
│   ├── 07_tools.sh                # Downloads/installs pentest tools from upstream
│   └── 08_dashboard.sh
│
├── config/
│   ├── ghostlink.conf             # Main config (populated by installer)
│   ├── device_profiles.json       # MAC spoofing profiles (60+ entries)
│   └── sources.conf               # Upstream URLs for all drivers and tools
│
├── system/
│   ├── banner.sh                  # CLI banner
│   ├── zram.sh
│   ├── ssd.sh
│   ├── fan.sh
│   └── udev_rules.sh
│
├── identity/
│   ├── engine.sh
│   ├── profiles.sh
│   ├── spoof.sh
│   ├── rotate.sh
│   ├── restore.sh
│   └── status.sh
│
├── network/
│   ├── detect.sh
│   ├── classify.sh
│   ├── setup_mgmt.sh
│   ├── setup_upstream.sh
│   ├── setup_hotspot.sh
│   ├── nat.sh
│   └── templates/
│       ├── hostapd.conf.j2
│       └── dnsmasq.conf.j2
│
├── pentest/
│   ├── engine.py                  # LLM pentest orchestration
│   ├── llm/
│   │   ├── client.py
│   │   ├── prompts.py
│   │   └── tools.py
│   ├── scan.py
│   ├── capture.py
│   ├── executor.py                # Calls installed tools (not bundled)
│   ├── reporter.py
│   └── attack/
│       ├── wifite.sh
│       ├── deauth.sh
│       ├── evil_twin.sh
│       └── pmkid.sh
│
├── dashboard/
│   ├── app.py
│   ├── api/
│   │   ├── network.py
│   │   ├── identity.py
│   │   ├── pentest.py
│   │   ├── terminal.py
│   │   └── system.py
│   ├── templates/
│   │   └── index.html
│   └── static/
│       ├── css/
│       └── js/
│
├── services/
│   ├── ghostlink.target
│   ├── gl-system.service
│   ├── gl-network.service
│   ├── gl-identity.service
│   ├── gl-dashboard.service
│   └── gl-fan.service
│
└── docs/
    └── ARCHITECTURE.md


/opt/ghostlink/                     ← installed on device (not in repo)
├── drivers/                        # Cloned + built at install time
│   ├── rtl8812au/                  #   → git clone aircrack-ng/rtl8812au
│   ├── rtl88x2bu/                  #   → git clone morrownr/88x2bu
│   └── rtl8188eus/                 #   → git clone aircrack-ng/rtl8188eus
├── tools/                          # Installed at install time
│   └── wifite2/                    #   → git clone kimocoder/wifite2
└── wordlists/
    └── rockyou.txt                 #   → downloaded from upstream


/var/lib/ghostlink/                 ← runtime state
├── identity.state
└── interfaces.map


/var/log/ghostlink/                 ← logs and reports
├── pentest.log
├── system.log
└── reports/
```

---

## Zero-Bundle Policy: Drivers

No driver source code ships with Ghostlink. The install script detects connected USB adapters
via `lsusb` and clones only what is needed.

### Driver Source Map

```
config/sources.conf defines:

RTL8812AU
  git_url  = https://github.com/aircrack-ng/rtl8812au
  branch   = v5.6.4.2
  install  = dkms

RTL882xBU  (covers RTL8822BU, RTL8812BU)
  git_url  = https://github.com/morrownr/88x2bu-20210702
  branch   = main
  install  = dkms

RTL8188EUS
  git_url  = https://github.com/aircrack-ng/rtl8188eus
  branch   = v5.3.9
  install  = dkms
```

### Detection → Install Flow

```
lsusb output
  │
  ├── 0bda:8812  → RTL8812AU  → clone aircrack-ng/rtl8812au  → dkms install
  ├── 0bda:b812  → RTL8812BU  → clone morrownr/88x2bu        → dkms install
  ├── 0bda:881a  → RTL8821AU  → clone aircrack-ng/rtl8812au  → dkms install
  ├── 0bda:8179  → RTL8188EUS → clone aircrack-ng/rtl8188eus → dkms install
  └── unknown    → warn user, skip
```

### Why DKMS

DKMS rebuilds kernel modules automatically after every `apt upgrade` that bumps the kernel.
Without DKMS, a routine OS update would silently break all external WiFi adapters.

### Kernel Prerequisites (apt, installed before driver clone)

```
linux-headers-$(uname -r)
build-essential
dkms
git
```

---

## Zero-Bundle Policy: Pentest Tools

No tool binary or source ships with Ghostlink. `07_tools.sh` fetches each tool from its
upstream source. `ghostlink update-tools` re-runs the same logic for updates.

### Tool Source Map

```
config/sources.conf defines:

SYSTEM TOOLS (apt)
  aircrack-ng        apt: aircrack-ng
  hcxtools           apt: hcxtools
  hcxdumptool        apt: hcxdumptool
  hashcat            apt: hashcat
  hostapd            apt: hostapd
  dnsmasq            apt: dnsmasq
  reaver             apt: reaver
  macchanger         apt: macchanger
  net-tools          apt: net-tools iw wireless-tools
  python3-deps       apt: python3 python3-pip python3-venv
  tcpdump            apt: tcpdump

GIT TOOLS (cloned to /opt/ghostlink/tools/)
  wifite2
    git_url  = https://github.com/kimocoder/wifite2
    branch   = master
    install  = pip install -e .

  bettercap
    method   = go install (or apt fallback)
    source   = github.com/bettercap/bettercap@latest

PYTHON PACKAGES (pip, in /opt/ghostlink/venv)
  flask
  flask-sock
  gunicorn
  psutil
  scapy
  anthropic          # Claude LLM client
  openai             # OpenAI fallback
```

### Update Command

```bash
ghostlink update-tools
  │
  ├── apt update && apt upgrade <system_tools>
  ├── for each git tool: git -C /opt/ghostlink/tools/<name> pull && reinstall
  └── pip install --upgrade <python_packages>
```

---

## Zero-Bundle Policy: Frontend Assets

xterm.js and Pico.css are not committed to the repo.
The install script downloads pinned versions during `08_dashboard.sh`.

```
XTERM_VERSION=5.3.0
PICO_VERSION=2.0.6

Downloaded to /opt/ghostlink/dashboard/static/
  xterm.js  → cdn.jsdelivr.net/npm/xterm@${XTERM_VERSION}/lib/xterm.js
  xterm.css → cdn.jsdelivr.net/npm/xterm@${XTERM_VERSION}/css/xterm.css
  pico.css  → cdn.jsdelivr.net/npm/@picocss/pico@${PICO_VERSION}/css/pico.min.css
```

Versions are pinned in `config/sources.conf` and can be bumped independently.

---

## System Optimization Layer

### ZRAM
```
Physical RAM:    2048 MB
ZRAM size:       2048 MB  (zstd compression, RPi-only)
NVMe Swap:       2048 MB  (emergency only)
Total effective: ~6 GB

Swappiness:      60 (prioritize ZRAM over physical eviction)
Priority order:  ZRAM (priority=100) > NVMe Swap (priority=10)
```

### M.2 NVMe
```
I/O Scheduler:   none       (optimal for NVMe, bypasses elevator)
Mount flags:     noatime,nodiratime
queue_depth:     1024
readahead:       8192 KB
dirty_ratio:     10%
fstrim:          weekly systemd timer
```

### Fan (PWM via /sys)
```
< 50°C   → 0%    (silent)
50–60°C  → 30%   (light)
60–70°C  → 60%   (medium) ← default operating zone
> 70°C   → 100%  (full)
> 80°C   → emergency warning + log
```

---

## Identity System (KROVEX → Ghostlink)

### Root Cause of KROVEX Failure

```
KROVEX assumed:   wlan0 = onboard, wlan1 = RTL8812AU, wlan2 = RTL882xBU
Reality:          USB enumeration order is non-deterministic
Result:           After any reboot/replug, interface roles silently swap
```

### Ghostlink Fix

Every adapter is classified by probing actual capabilities at boot, not by assumed name.
`udev .link` files then lock the assigned alias permanently.

```
classify.sh at boot:
  for each interface:
    probe: iw phy supports monitor?  → monitor_capable=true/false
    probe: iw phy supports AP?       → ap_capable=true/false
    probe: vendor OUI from /sys      → chipset hint

  assign:
    monitor_capable + ap_capable + not onboard  → gl-upstream  (highest priority)
    ap_capable + not onboard                    → gl-hotspot
    onboard                                     → gl-mgmt

  write /etc/systemd/network/10-gl-upstream.link  (MatchMACAddress=...)
  write /etc/systemd/network/10-gl-hotspot.link
  write /etc/systemd/network/10-gl-mgmt.link
```

### Identity Profiles (device_profiles.json)

60+ device profiles, each with:
- Real IEEE OUI prefix (preserves vendor legitimacy)
- DHCP hostname that matches the device type
- Optional user-agent string for HTTP interactions

```json
{
  "iphone_15_pro": {
    "oui": "A4:C3:F0",
    "vendor": "Apple Inc.",
    "hostname": "iPhone",
    "description": "Apple iPhone 15 Pro"
  },
  "macbook_pro_m3": {
    "oui": "3C:22:FB",
    "vendor": "Apple Inc.",
    "hostname": "MacBook-Pro",
    "description": "Apple MacBook Pro M3"
  },
  "samsung_s24": {
    "oui": "8C:79:F0",
    "vendor": "Samsung Electronics",
    "hostname": "Galaxy-S24",
    "description": "Samsung Galaxy S24"
  }
}
```

### Spoof Mechanism

```bash
# spoof.sh (simplified)
ip link set dev gl-upstream down
ip link set dev gl-upstream address ${new_mac}
ip link set dev gl-upstream up

# Update DHCP client hostname
sed -i "s/send host-name.*/send host-name \"${hostname}\";/" /etc/dhcp/dhclient.conf
dhclient -r gl-upstream && dhclient gl-upstream

# Save state
echo "profile=${profile} mac=${new_mac} real_mac=${real_mac}" > /var/lib/ghostlink/identity.state
```

---

## LLM-Driven Pentest Engine

### ReAct Loop

```
┌─────────────────────────────────────────────────┐
│                  PENTEST LOOP                   │
│                                                 │
│  scan_results ──→ LLM ──→ tool_call             │
│       ↑              ↑         │                │
│  update_context   history   executor            │
│       └──────────── result ←──┘                │
│                                                 │
│  exits when: success | all vectors exhausted    │
└─────────────────────────────────────────────────┘
```

### LLM Tool Schema

```python
PENTEST_TOOLS = [
    Tool("scan_networks",     "Scan with airodump-ng, return SSIDs/BSSIDs/clients/security"),
    Tool("get_clients",       "List active clients on a specific BSSID"),
    Tool("capture_handshake", "Deauth client and capture WPA 4-way handshake"),
    Tool("pmkid_attack",      "Collect PMKID hash via hcxdumptool (clientless)"),
    Tool("deauth_all",        "Broadcast deauth on BSSID"),
    Tool("evil_twin",         "Launch rogue AP to capture credentials"),
    Tool("crack_hash",        "Run hashcat against captured hash + wordlist"),
    Tool("wps_pixiedust",     "Run reaver WPS Pixie-Dust attack"),
    Tool("wps_pin_bruteforce","Run reaver WPS PIN brute-force"),
    Tool("report",            "Generate final pentest report and exit loop"),
]
```

### LLM Providers

| Provider   | Model              | Config key   | Notes                       |
|------------|--------------------|--------------|-----------------------------|
| Claude     | claude-sonnet-4-6  | `claude`     | Default — best reasoning    |
| OpenAI     | gpt-4o             | `openai`     | Alternative                 |
| Groq       | llama-3.3-70b      | `groq`       | Fast, cost-effective        |
| Ollama     | mistral 7B         | `ollama`     | Offline — RAM-constrained   |

No API key configured → rule-based fallback mode (fixed attack sequence).

### Report Output

```markdown
# Ghostlink Pentest Report
**Date:** 2025-01-15 14:32
**Target:** SSID "CafeWifi" / BSSID AA:BB:CC:DD:EE:FF
**Duration:** 8m 42s

## Attack Sequence
1. PMKID capture → hash collected in 45s
2. Hashcat (rockyou) → cracked in 3m 12s

## Result: SUCCESS
**Credential:** password123

## Recommendations
- Enable WPA3 or use a 20+ character random passphrase
- Disable WPS (currently enabled, exploitable)
```

---

## Dashboard Architecture

**Stack:** Flask + flask-sock + Gunicorn + Nginx + Pico.css + xterm.js (all fetched at install)

### Terminal (xterm.js + PTY)

```
Browser xterm.js
    │ WebSocket ws://device/terminal
Flask-sock handler
    │ pty.fork()
Real bash process (runs as ghostlink user, sudoers for specific commands)
```

### Dashboard Panels

| Panel        | Data Source              | Update Method |
|--------------|--------------------------|---------------|
| System       | psutil                   | SSE 2s        |
| Network      | ip/iw commands           | SSE 5s        |
| Identity     | identity.state           | SSE on change |
| Pentest      | engine.py events         | SSE streaming |
| Terminal     | PTY/WebSocket            | Real-time WS  |
| Hotspot      | dnsmasq leases           | SSE 10s       |
| Logs         | journald / log files     | SSE streaming |

---

## Installation Flow

```
sudo ./install/install.sh
│
├── [1/8] PREFLIGHT
│   ├── Detect RPi 5 (check /proc/cpuinfo model)
│   ├── Detect NVMe SSD (/dev/nvme0 present)
│   ├── Count USB WiFi adapters (lsusb + iw dev)
│   ├── Internet connectivity (ping 8.8.8.8)
│   └── Disk space check (min 8GB free)
│
├── [2/8] SYSTEM OPTIMIZATION
│   ├── apt update && apt upgrade -y
│   ├── ZRAM: install zram-tools, configure /etc/default/zramswap
│   ├── NVMe: set scheduler + readahead via udev rule
│   ├── Kernel params: /etc/sysctl.d/99-ghostlink.conf
│   └── Fan daemon: install gl-fan.service
│
├── [3/8] DRIVERS
│   ├── apt install linux-headers-$(uname -r) build-essential dkms git
│   ├── lsusb → detect connected RTL chipsets
│   ├── For each detected chipset:
│   │   ├── git clone <upstream_url> /opt/ghostlink/drivers/<name>
│   │   ├── dkms add + dkms build + dkms install
│   │   └── Verify: modprobe + interface appears in iw dev
│   └── FAIL FAST: abort if dkms build fails (not silent continue)
│
├── [4/8] INTERFACE CLASSIFICATION
│   ├── probe all interfaces for monitor/AP capability
│   ├── assign gl-mgmt / gl-upstream / gl-hotspot roles
│   └── write udev .link files → reload udev → rename interfaces
│
├── [5/8] IDENTITY SYSTEM
│   ├── Read and store real MACs → /var/lib/ghostlink/real_macs
│   ├── Install device_profiles.json → /etc/ghostlink/
│   └── Apply initial random identity to gl-upstream
│
├── [6/8] NETWORK CONFIGURATION
│   ├── PROMPT: Management WiFi mode?
│   │   ├── A) Existing network → enter SSID + password
│   │   └── B) Custom config → enter SSID + password (stored in config)
│   ├── PROMPT: Hotspot SSID and password?
│   ├── apt install hostapd dnsmasq
│   ├── Render hostapd.conf from template
│   ├── Render dnsmasq.conf from template
│   ├── Configure iptables NAT (MASQUERADE on gl-upstream)
│   └── Install iptables-persistent
│
├── [7/8] PENTEST TOOLS
│   ├── apt install aircrack-ng hcxtools hcxdumptool hashcat reaver macchanger tcpdump
│   ├── git clone wifite2 → /opt/ghostlink/tools/wifite2 → pip install -e .
│   ├── install bettercap (go install or apt)
│   ├── python3 venv → /opt/ghostlink/venv
│   ├── pip install flask flask-sock gunicorn psutil scapy anthropic openai
│   └── Download wordlist (rockyou.txt) → /opt/ghostlink/wordlists/
│
└── [8/8] DASHBOARD & SERVICES
    ├── Download xterm.js + Pico.css (pinned versions from CDN)
    ├── Copy dashboard source → /opt/ghostlink/dashboard/
    ├── Install all systemd services
    ├── systemctl enable + start ghostlink.target
    ├── ln -sf /opt/ghostlink/ghostlink /usr/local/bin/ghostlink
    └── Display banner + status summary
```

---

## CLI Interface

```bash
ghostlink                      # Show banner + status
ghostlink status               # Detailed system status
ghostlink identity             # Current identity info
ghostlink identity rotate      # Switch to random new identity
ghostlink identity set <name>  # Set specific profile
ghostlink identity list        # List all available profiles
ghostlink scan                 # Scan surrounding networks
ghostlink pentest start        # Start AI-driven pentest loop
ghostlink pentest stop         # Stop pentest
ghostlink pentest report       # Show last pentest report
ghostlink hotspot on/off       # Enable/disable hotspot
ghostlink dashboard            # Print dashboard URL
ghostlink update-tools         # Update all tools to latest
ghostlink logs                 # Live system log stream
ghostlink doctor               # Diagnose interface/driver/service issues
```

---

## RAM Budget (2GB)

| Component              | Usage        |
|------------------------|--------------|
| OS kernel + systemd    | ~180 MB      |
| Network daemons        | ~50 MB       |
| Dashboard (Flask+gunicorn) | ~40 MB  |
| Identity + fan daemons | ~15 MB       |
| Buffer / cache         | ~300 MB      |
| **Free for pentest ops** | **~1100 MB** |
| + ZRAM effective bonus | +~1000 MB    |

---

## Security

- Dashboard bound to gl-mgmt interface only (not reachable from hotspot clients)
- HTTPS with self-signed cert generated at install time
- PTY terminal runs as dedicated `ghostlink` user with narrow sudoers for specific commands
- All pentest operations logged to `/var/log/ghostlink/pentest.log`
- `ghostlink identity restore` always available regardless of system state
- iptables default policy: DROP on gl-hotspot input (only FORWARD allowed)

---

## Implementation Priority

```
[1] System base layer      install/02_system.sh    ZRAM + NVMe + fan + sysctl
[2] Driver system          install/03_drivers.sh   chipset detect + DKMS fetch/build
[3] Interface engine       install/04_interfaces.sh classify + udev naming
[4] Identity system        identity/               spoof engine + 60+ profiles
[5] Network management     network/ + install/06   NAT + hostapd + dnsmasq
[6] Pentest engine         pentest/                LLM loop + tool wrappers
[7] Dashboard              dashboard/              Flask + xterm.js + Pico.css
[8] Install script         install/install.sh      ties 1-7 together
```
