# GhostLink

**Autonomous wireless pentest and network operations platform for Raspberry Pi 5.**

Deploy. Classify. Intercept. Route. Persist.

---

## What is GhostLink?

GhostLink turns a Raspberry Pi 5 into a self-contained wireless intelligence platform. It manages multiple USB WiFi adapters with deterministic interface naming, handles driver installation automatically, provides a state machine for switching between monitor/injection/AP modes, shares internet through a local hotspot, and exposes everything through a CLI and HTTPS dashboard.

Current status: **early active development — first real hardware testing is the next milestone.**

---

## Hardware Target

| Component | Role |
|-----------|------|
| Raspberry Pi 5 (2 GB RAM) | Platform host |
| Pi onboard WiFi (BCM43455) | `gl-mgmt` — management / SSH / CLI / dashboard |
| RTL8812AU (USB) | `gl-upstream` — pentest + upstream WiFi client |
| RTL88x2BU (USB) | `gl-hotspot` — preferred distribution AP |
| RTL8188EUS (USB) | `gl-aux` — auxiliary scanning + fallback AP |
| NVMe M.2 SSD | OS and storage |

GhostLink uses driver-based interface naming via systemd `.link` files and udev rules, so interface names are stable regardless of USB enumeration order or adapter plug sequence.

---

## Supported Adapters

| Chipset | Module | Role | Notes |
|---------|--------|------|-------|
| RTL8812AU | `88XXau` | `gl-upstream` | aircrack-ng tree; monitor + injection |
| RTL88x2BU | `88x2bu` | `gl-hotspot` | morrownr; AP mode preferred |
| RTL8188EUS | `8188eu` | `gl-aux` | aircrack-ng; auxiliary scan + fallback AP |
| BCM43455 | `brcmfmac` | `gl-mgmt` | Pi onboard; management only |

Known USB IDs handled by GhostLink udev rules:

- RTL8812AU: `0bda:8812`, `0bda:881a`, `0bda:8811`, `2357:0101`, `2357:0103`, `0bda:a811`
- RTL88x2BU: `0bda:b812`, `0bda:b820`, `0bda:b82c`, `2001:331e`, `0bda:c820`
- RTL8188EUS: `0bda:8179`, `0bda:8178`, `0bda:817e`, `0bda:0179`, `2001:3311`, `2357:010c`

---

## OS Targets

| OS | Status | Notes |
|----|--------|-------|
| Raspberry Pi OS Bookworm (64-bit) | **Primary** | Full feature set |
| Raspberry Pi OS Trixie (64-bit) | **Primary** | Full feature set |
| DietPi (Raspberry Pi) | Supported | Lighter footprint |
| Kali Linux | Supported | Pentest-native, many tools pre-installed |
| Debian | Template | Structure in place, not fully tested |
| Ubuntu | Template | Structure in place, not fully tested |

2GB ZRAM is a Raspberry Pi deployment optimization — configured automatically on Raspberry Pi OS and DietPi. It is skipped by default on generic Debian, Ubuntu, and Kali unless running on Raspberry Pi hardware with explicit enablement.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Raspberry Pi 5                                │
│                                                                 │
│  gl-mgmt (BCM43455)    ← SSH / CLI / Dashboard                 │
│    never default route; SSH stays alive throughout              │
│                                                                 │
│  gl-upstream (RTL8812AU) ← pentest / monitor / upstream client │
│    state machine: idle → monitor → station → connected          │
│    mode switch via iw type (no airmon-ng rename)                │
│                                                                 │
│  gl-hotspot (RTL88x2BU) ← distribution AP (preferred)          │
│  gl-aux     (RTL8188EUS) ← auxiliary scan / fallback AP         │
│                                                                 │
│  NAT + policy routing:                                          │
│    fwmark 0x50 on hotspot client packets (mangle PREROUTING)    │
│    ip rule: fwmark 0x50 → ghostlink_upstream table (ID 200)     │
│    ghostlink_upstream table: default via upstream gateway        │
│    MASQUERADE on upstream interface                             │
│    Management (gl-mgmt): never forwarded, never NATed           │
│  iptables named chains — idempotent flush+reapply on restart    │
│                                                                 │
│  HTTPS dashboard → gl-mgmt IP:8080                             │
│  ghostlink CLI → /usr/local/bin/ghostlink                       │
└─────────────────────────────────────────────────────────────────┘
```

---

## CLI Features

```
ghostlink status                     System overview
ghostlink interfaces                 Hardware WiFi inventory
ghostlink interfaces roles           Interface → role mapping

ghostlink mgmt status                Management WiFi status
ghostlink mgmt keep                  Keep current connection (safe)
ghostlink mgmt configure SSID PASS   Connect gl-mgmt to WiFi
ghostlink mgmt reconnect             Reconnect using saved config

ghostlink upstream status            Current mode and state
ghostlink upstream monitor           Enable monitor mode
ghostlink upstream station           Restore managed mode
ghostlink upstream connect SSID PW   Connect to upstream WiFi
ghostlink upstream disconnect        Disconnect

ghostlink aux status                 RTL8188EUS auxiliary adapter status
ghostlink aux monitor                Switch gl-aux to monitor mode
ghostlink aux station                Switch gl-aux to managed mode
ghostlink aux scan                   Scan networks via gl-aux

ghostlink hotspot start              Start distribution AP
ghostlink hotspot stop               Stop AP
ghostlink hotspot status             Show interface and service state

ghostlink nat start                  Apply NAT + policy routing rules
ghostlink nat stop                   Remove NAT rules
ghostlink nat status                 Show NAT + routing rule status

ghostlink route status               Default/management/upstream route table + ip rules

ghostlink drivers status             Driver/module/interface summary
ghostlink drivers audit              Full RTL8812AU driver audit (USB, DKMS, caps, conflicts)
ghostlink drivers fix rtl8812au      Fix/reinstall RTL8812AU DKMS driver (add --force to reinstall)
ghostlink drivers monitor-test       Safe monitor mode test — upstream/aux only, restores mode

ghostlink wifi doctor                WiFi interface health check (all 4 roles)

ghostlink tools list                 Show all tools with install status
ghostlink tools info <tool>          Show tool details and example commands
ghostlink tools run <tool> -- <args> Run tool (native behavior preserved, no --kill)
ghostlink tools doctor wifite        Check wifite prerequisites

ghostlink scan                       Scan (auto monitor mode on gl-upstream)
ghostlink scan wifi [args]           Managed wifite launch (management-safe)
ghostlink pentest wifi [args]        Managed wifite launch (management-safe)
ghostlink pentest start              Begin automated pentest
ghostlink identity rotate            Rotate MAC/hostname to random profile
ghostlink identity set <profile>     Set specific device identity
ghostlink identity list              List available profiles
ghostlink doctor                     Diagnose all interfaces and services
ghostlink logs                       Live log stream
ghostlink update                     Pull and apply latest GhostLink from git
ghostlink update --dry-run           Preview update without applying
ghostlink update-tools               Update pentest tools only
ghostlink version                    Show version, commit, install paths
ghostlink console                    Interactive command console
ghostlink dashboard                  Print dashboard URL (prefers management IP)
```

---

## Web Dashboard

Accessible at `https://<mgmt-ip>:8080` (self-signed TLS).

- Live interface status (gl-mgmt / gl-upstream / gl-hotspot / gl-aux)
- Upstream mode switching (monitor / station / connect)
- Auxiliary adapter status and mode control
- Hotspot start / stop / status + fallback indicator
- NAT control
- Identity management
- Network scan trigger + results
- Pentest engine control
- Terminal (xterm.js WebSocket)
- System metrics (CPU, memory, temperature)

---

## Wireless Workflow

```
1. Boot → gl-mgmt connects to management WiFi (default: keep existing)
2. ghostlink upstream connect "TargetNet" "password"
   → gl-upstream gets IP, becomes default route (metric 100)
3. ghostlink hotspot start
   → gl-hotspot (or gl-aux fallback) broadcasts AP
   → clients get 192.168.50.x DHCP leases
4. ghostlink nat start
   → client traffic → gl-hotspot → RPi → gl-upstream → internet
5. ghostlink upstream monitor
   → gl-upstream switches to monitor mode (iw type, same interface name)
6. ghostlink scan
   → captures surrounding networks via gl-upstream
7. ghostlink aux scan
   → simultaneous scan via gl-aux while gl-upstream is in use elsewhere
8. ghostlink identity rotate
   → randomizes MAC + hostname fingerprint on gl-upstream
```

---

## Install / Quick Start

```bash
# Clone
git clone https://github.com/omerbaysoy/Ghostlink.git
cd Ghostlink

# Dry run (no changes) — verify what will happen
sudo ./install/install.sh --dry-run --os rpi-bookworm
sudo ./install/install.sh --dry-run --os rpi-trixie

# Install (Raspberry Pi OS Trixie — primary target)
sudo ./install/install.sh --os rpi-trixie

# Install (Raspberry Pi OS Bookworm)
sudo ./install/install.sh --os rpi-bookworm

# Install on DietPi (Raspberry Pi)
sudo ./install/install.sh

# Skip driver build if drivers already working
sudo ./install/install.sh --os rpi-trixie --skip-drivers

# After install
ghostlink status
ghostlink doctor
ghostlink interfaces roles
```

---

## First Hardware Test

After install, follow [docs/FIRST_TEST.md](docs/FIRST_TEST.md) for the full A–L test sequence covering management WiFi, adapter detection, RTL8812AU driver, RTL8188EUS driver, monitor modes, upstream connect, hotspot, fallback AP, NAT, and ZRAM.

Quick checks:
```bash
ghostlink doctor
ghostlink interfaces
ghostlink aux status
ghostlink hotspot status
ghostlink nat status

ip link show gl-mgmt gl-upstream gl-hotspot gl-aux
lsusb | grep -iE 'realtek|0bda|rtl|tp-link'
lsmod | grep -E 'brcmfmac|88XXau|88x2bu|8188eu'
systemctl status ghostlink.target gl-system gl-network gl-dashboard --no-pager
journalctl -u gl-network -n 100 --no-pager
```

---

## Screenshots

_Placeholder — dashboard screenshots to be added after first hardware test._

---

## Repository Structure

```
Ghostlink/
├── config/
│   ├── ghostlink.conf       # Main configuration
│   ├── sources.conf         # URLs, USB IDs, package names
│   └── device_profiles.json # MAC spoofing profiles
├── dashboard/
│   ├── app.py               # Flask application
│   └── api/                 # API blueprints (network, identity, system...)
├── docs/
│   └── FIRST_TEST.md        # A–L hardware test sequence
├── identity/                # MAC spoofing, profile rotation
├── install/
│   ├── install.sh           # Main installer
│   ├── lib/                 # detect.sh, ui.sh, net.sh
│   ├── os/                  # OS profiles (rpi-bookworm, rpi-trixie, kali...)
│   └── steps/               # 01_preflight → 08_dashboard
├── network/
│   ├── classify.sh          # Driver-based interface naming + udev rules
│   ├── hw_inventory.sh      # Hardware inventory (text + JSON)
│   ├── mgmt.sh              # Management WiFi (gl-mgmt)
│   ├── upstream_mode.sh     # Upstream state machine (gl-upstream)
│   ├── setup_hotspot.sh     # Hotspot setup (gl-hotspot + gl-aux fallback)
│   ├── nat.sh               # NAT/forwarding (reads effective hotspot iface)
│   └── templates/           # hostapd.conf.j2, dnsmasq.conf.j2
├── pentest/                 # Scan, capture, LLM-assisted engine
├── services/                # systemd units
├── system/                  # zram.sh (RPi-only), fan.sh, ssd.sh
└── ghostlink                # CLI entry point
```

---

## Roadmap

- [x] Multi-adapter detection and deterministic naming (driver-based .link files)
- [x] RTL8812AU driver with aarch64 (RPi 5) Makefile patch
- [x] RTL8188EUS (gl-aux) support — auxiliary scan + fallback AP
- [x] Management WiFi protection (never breaks SSH, never default route)
- [x] gl-upstream state machine (monitor / station / connect)
- [x] Idempotent NAT + policy routing (ghostlink_upstream table, fwmark 0x50)
- [x] Management-safe forwarding (gl-mgmt never in FORWARD chain)
- [x] RTL8812AU driver audit, fix, and monitor mode test CLI
- [x] WiFi health check (ghostlink wifi doctor)
- [x] Fallback hotspot: gl-aux when gl-hotspot unavailable
- [x] Raspberry Pi-only 2GB ZRAM (zstd, priority 100)
- [x] HTTPS dashboard with WebSocket terminal
- [x] Identity rotation (MAC + hostname spoofing)
- [x] Installed CLI: /usr/local/bin/ghostlink → /opt/ghostlink/ghostlink symlink
- [x] Self-update: ghostlink update [--dry-run|--force] with backup and git pull
- [x] ghostlink version: commit, branch, remote, OS profile, last update
- [x] Tool registry: ghostlink tools list/info/run/doctor with 27 tool definitions
- [x] Safe wifite wrapper: never uses mgmt/hotspot/trusted-connected interfaces
- [x] Management-safe capture.py: no airmon-ng check kill, uses iw type instead
- [x] Tool additions: nmap, arp-scan, netdiscover, iperf3, mtr, traceroute, dnsutils, whois, ethtool, bully
- [x] ghostlink console: interactive command loop
- [ ] First real hardware validation on RPi 5
- [ ] LLM-assisted pentest automation
- [ ] Evil twin / captive portal
- [ ] PMKID/handshake capture pipeline
- [ ] Multi-target tracking and reporting

---

## Development Status

GhostLink is in **early active development**. The installer, network management layer, CLI, and dashboard are implemented and syntax-validated. First real hardware testing on Raspberry Pi 5 with the four-adapter setup (onboard + three USB) is the next milestone.

Contributions, bug reports, and hardware test results are welcome via GitHub Issues.
