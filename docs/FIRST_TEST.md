# Ghostlink — First Hardware Test Sequence

Raspberry Pi 5 (2 GB RAM + 256 GB NVMe).  Run each section in order.
All commands run as root (`sudo -i` or from root shell).

---

## A — Management WiFi (gl-mgmt)

Goal: SSH access stays alive throughout; gl-mgmt never becomes the default route.

```bash
# 1. Confirm interface exists and has IP
ip link show gl-mgmt
ip -4 addr show gl-mgmt          # expect DHCP lease or manual IP

# 2. Confirm gl-mgmt is NOT the default route
ip route show default             # should NOT list gl-mgmt

# 3. Show mgmt state
ghostlink mgmt status

# 4. SSH from another machine to confirm connectivity is intact
#    ssh pi@<mgmt-ip>
```

Expected: IP assigned, no default route via gl-mgmt, SSH works throughout.

---

## B — Adapter Detection

Goal: All three RTL adapters appear under assigned interface names.

```bash
# 1. List USB WiFi devices
lsusb | grep -iE "realtek|0bda|2357|tp-link"

# 2. Hardware inventory
ghostlink interfaces

# 3. Check interface names
ip link show gl-upstream    # RTL8812AU  — pentest/upstream
ip link show gl-hotspot     # RTL88x2BU  — preferred hotspot
ip link show gl-aux         # RTL8188EUS — auxiliary/fallback

# 4. Check role assignment
ghostlink interfaces roles

# 5. Check drivers loaded
lsmod | grep -E "88XXau|88x2bu|8188eu|brcmfmac"
```

Expected:
- `gl-upstream` → driver `88XXau`
- `gl-hotspot` → driver `88x2bu`
- `gl-aux` → driver `8188eu`
- All present, operstate `DOWN` or `UP`

If an interface is missing:
```bash
# Check udev rules applied
cat /etc/udev/rules.d/72-ghostlink-wifi.rules

# Check .link files
ls /etc/systemd/network/10-gl-*.link

# Force udev re-trigger (unplug/replug adapter first)
udevadm control --reload-rules && udevadm trigger --subsystem-match=net
sleep 2
ip link show
```

---

## C — RTL8812AU Driver (gl-upstream / pentest)

Goal: 88XXau loaded, gl-upstream supports monitor + packet injection.

```bash
# 1. Module loaded?
lsmod | grep 88XXau

# 2. Manual probe if not loaded
modprobe 88XXau
lsmod | grep 88XXau

# 3. Monitor mode capability
phy=$(iw dev gl-upstream info | awk '/wiphy/{print "phy"$2}')
iw phy "$phy" info | grep -A20 "Supported interface modes"
# Expect "* monitor" and "* managed" in the list

# 4. Toggle monitor mode
ghostlink upstream monitor
iw dev gl-upstream info          # type should be "monitor"

ghostlink upstream station
iw dev gl-upstream info          # type should be "managed"
```

Expected: Monitor mode toggle works, interface name stays `gl-upstream` throughout.

Troubleshoot if 88XXau not loading:
```bash
cat /etc/modprobe.d/ghostlink-realtek.conf   # blacklist must be present
lsmod | grep -E "rtl8xxxu|rtw88"             # conflicting in-tree drivers?
rmmod rtl8xxxu rtw88_8822bu rtw88_usb rtw88_8812au 2>/dev/null || true
modprobe 88XXau
dkms status                                  # check DKMS build status
```

---

## D — RTL8188EUS Driver (gl-aux / auxiliary)

Goal: 8188eu loaded, gl-aux present and capable of monitor + AP mode.

```bash
# 1. USB detected?
lsusb | grep -E "0bda:8179|0bda:817[e8]|2357:010c|2001:3311"

# 2. Module loaded?
lsmod | grep 8188eu

# 3. Manual probe if not loaded
modprobe 8188eu
lsmod | grep 8188eu

# 4. Interface present?
ip link show gl-aux
iw dev gl-aux info

# 5. Check mode capabilities
phy=$(iw dev gl-aux info | awk '/wiphy/{print "phy"$2}')
iw phy "$phy" info | grep -A20 "Supported interface modes"
# Expect "* monitor" and "* AP" in the list (aircrack-ng 8188eus driver)

# 6. Full status
ghostlink aux status
```

Expected: `gl-aux` present, driver `8188eu`, monitor and AP mode supported.

Troubleshoot:
```bash
dkms status | grep 8188
journalctl -b | grep -i "8188\|rtl8188"
# If DKMS build failed, re-run driver installation:
# sudo /opt/ghostlink/install/steps/03_drivers.sh /opt/ghostlink
```

---

## E — RTL8188EUS Monitor Mode (auxiliary scan)

Goal: gl-aux can scan networks independently of gl-upstream.

```bash
# Switch gl-aux to monitor mode
ghostlink aux monitor
iw dev gl-aux info          # type should be "monitor"

# Auxiliary scan
ghostlink aux scan

# Or raw airodump-ng on gl-aux
airodump-ng gl-aux
# Ctrl-C after a few seconds

# Restore managed mode
ghostlink aux station
```

Expected: Table of SSIDs/BSSIDs visible via gl-aux.

---

## F — Scan Test (gl-upstream primary scan)

Goal: gl-upstream sees surrounding networks in monitor mode.

```bash
# Scan (auto-switches to monitor if needed)
ghostlink scan

# Longer scan
ghostlink scan gl-upstream --duration 20
```

Expected: Table of SSIDs, BSSIDs, channels, signal levels.

---

## G — Upstream Connect Test

Goal: gl-upstream connects to a real WiFi network and provides internet.

```bash
# Switch to station mode
ghostlink upstream station

# Connect to a known network
ghostlink upstream connect "YourSSID" "YourPassword"

# Check IP assigned
ip -4 addr show gl-upstream
ip route show                # gl-upstream should be default route metric 100

# Test internet via gl-upstream
curl --interface gl-upstream https://ifconfig.me

# Check upstream state
ghostlink upstream status
```

Expected: IP via DHCP, default route through gl-upstream, internet reachable.

---

## H — Hotspot Test (primary: gl-hotspot)

Goal: gl-hotspot broadcasts AP, clients connect and get IPs.

```bash
# Review config
grep -A10 '\[hotspot\]' /etc/ghostlink/ghostlink.conf

# Start hotspot
ghostlink hotspot start

# Status
ghostlink hotspot status
systemctl status hostapd dnsmasq --no-pager

# Check AP broadcasting
iw dev gl-hotspot info

# Connect a client device to the SSID (default: GhostNet)
# Client should get 192.168.50.x
# Confirm from client: ping 192.168.50.1
```

Troubleshoot:
```bash
journalctl -u hostapd -n 50
journalctl -u dnsmasq -n 50
cat /etc/hostapd/hostapd.conf
```

---

## I — RTL8188EUS Fallback Hotspot

Goal: gl-aux can serve as AP when RTL88x2BU (gl-hotspot) is unavailable.

```bash
# Enable fallback in config
sed -i 's/fallback_hotspot=false/fallback_hotspot=true/' /etc/ghostlink/ghostlink.conf

# Stop gl-hotspot (simulate missing)
ip link set gl-hotspot down 2>/dev/null || true

# Start hotspot — should auto-use gl-aux
ghostlink hotspot start

# Verify fallback is active
ghostlink hotspot status
cat /run/ghostlink/hotspot.state

# Verify NAT uses correct interface
ghostlink nat status
```

Expected: hostapd active on `gl-aux`, hotspot.state shows `HOTSPOT_IFACE=gl-aux`.

---

## J — NAT / Internet Sharing Test

Prerequisites: Section G (upstream connected) and H or I (hotspot active) complete.

```bash
# Verify NAT rules
ghostlink nat status

# Apply / re-apply if needed
ghostlink nat start

# From a client on the hotspot:
#   ping 8.8.8.8
#   curl https://ifconfig.me

# Confirm forwarding is on
sysctl net.ipv4.ip_forward    # expect 1

# Check iptables chains
iptables -L GHOSTLINK_FORWARD -v
iptables -t nat -L GHOSTLINK_NAT -v
```

Expected: Client traffic exits via gl-upstream, client gets internet.

---

## K — ZRAM (Raspberry Pi only)

Goal: 2GB ZRAM swap active with zstd compression.

```bash
# Check if ZRAM is active
swapon --show
# Expect: /dev/zram0  size=2G  priority=100

# Check compression
cat /sys/block/zram0/comp_algorithm
# Expect: [zstd] or zstd

# Check size
cat /sys/block/zram0/disksize
# Expect: 2147483648 (2 GB in bytes)

# Full ZRAM status
zramctl
```

Expected: `/dev/zram0` active, 2GB, zstd, priority 100.

Troubleshoot:
```bash
systemctl status gl-system --no-pager
journalctl -u gl-system -n 30 --no-pager
# Manually run ZRAM setup:
bash /opt/ghostlink/system/zram.sh apply
```

---

## L — Doctor and Full Log Collection

Run after all tests and collect before filing issues.

```bash
ghostlink doctor

# Interface and route snapshot
ip link
ip route
ip -4 addr

# Service status
systemctl status ghostlink.target gl-system gl-network gl-identity gl-dashboard --no-pager

# Logs
journalctl -u gl-network  -n 100 --no-pager
journalctl -u gl-identity -n 50  --no-pager
journalctl -u gl-system   -n 50  --no-pager
journalctl -u hostapd     -n 50  --no-pager
journalctl -u dnsmasq     -n 50  --no-pager

# Drivers
dkms status
lsmod | grep -E "88XXau|88x2bu|8188eu|brcmfmac|rtl8xxxu|rtw88"

# NAT and USB
iptables -L -v --line-numbers
iptables -t nat -L -v
lsusb | grep -iE "0bda|2357|realtek"
```

---

## Quick Pass / Fail Summary

| Test | Command | Pass criteria |
|------|---------|---------------|
| mgmt IP | `ip -4 addr show gl-mgmt` | Shows IP |
| No default via mgmt | `ip route show default` | gl-mgmt not listed |
| gl-upstream exists | `ip link show gl-upstream` | Interface present |
| gl-hotspot exists | `ip link show gl-hotspot` | Interface present |
| gl-aux exists | `ip link show gl-aux` | Interface present |
| 88XXau loaded | `lsmod \| grep 88XXau` | Module listed |
| 8188eu loaded | `lsmod \| grep 8188eu` | Module listed |
| Monitor mode | `ghostlink upstream monitor` | Returns 0, iw shows monitor |
| Aux status | `ghostlink aux status` | Monitor=yes, AP=yes |
| Aux scan | `ghostlink aux scan` | APs visible |
| Scan | `ghostlink scan` | Table of APs appears |
| Upstream connect | `ghostlink upstream connect SSID PW` | IP assigned |
| Hotspot start | `ghostlink hotspot start` | hostapd active |
| Fallback hotspot | disable gl-hotspot + `ghostlink hotspot start` | gl-aux used |
| NAT | `ghostlink nat status` | MASQUERADE rule present |
| Client internet | from client: `curl ifconfig.me` | Returns IP |
| ZRAM | `swapon --show` | /dev/zram0 2G priority=100 |
