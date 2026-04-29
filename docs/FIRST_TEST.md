# Ghostlink — First Hardware Test Sequence

RPi 5 (2 GB RAM + 256 GB NVMe).  Run each section in order.
All commands run as root (`sudo -i` or from root shell).

---

## A — Management WiFi (gl-mgmt)

Goal: SSH access stays alive throughout; gl-mgmt never becomes the default route.

```bash
# 1. Confirm interface exists and has IP
ip link show gl-mgmt
ip -4 addr show gl-mgmt          # expect 192.168.x.x or DHCP lease

# 2. Confirm it is the NOT default route
ip route show default             # should NOT list gl-mgmt

# 3. Show mgmt state
ghostlink mgmt status

# 4. SSH from another machine to confirm connectivity is intact
#    ssh pi@<mgmt-ip>
```

Expected: IP assigned, no default route via gl-mgmt, SSH works.

---

## B — Adapter Detection

Goal: Both RTL adapters appear under their assigned interface names.

```bash
# 1. List USB devices
lsusb | grep -iE "rtl|realtek|0bda"

# 2. Hardware inventory
ghostlink interfaces

# 3. Check interface names
ip link show gl-upstream
ip link show gl-hotspot

# 4. Check drivers loaded
lsmod | grep -E "88XXau|88x2bu|brcmfmac"
```

Expected:
- `gl-upstream` present, driver `88XXau`
- `gl-hotspot` present, driver `88x2bu`
- Both show `DOWN` operstate (not yet configured)

If either is missing:
```bash
# Check udev rules applied
cat /etc/udev/rules.d/72-ghostlink-wifi.rules

# Check systemd .link files
cat /etc/systemd/network/10-gl-upstream.link
cat /etc/systemd/network/10-gl-hotspot.link

# Force udev re-trigger (unplug/replug adapter first)
udevadm control --reload-rules
udevadm trigger --subsystem-match=net
```

---

## C — RTL8812AU Driver (gl-upstream)

Goal: Confirm 88XXau is loaded and gl-upstream supports monitor mode.

```bash
# 1. Driver loaded?
lsmod | grep 88XXau

# 2. If not loaded — probe manually
modprobe 88XXau
lsmod | grep 88XXau

# 3. Interface exists?
ip link show gl-upstream

# 4. Monitor mode capable?
iw dev gl-upstream info
iw phy $(iw dev gl-upstream info | awk '/wiphy/{print "phy"$2}') info | grep -A20 "Supported interface modes"
# Expect "* monitor" in the list

# 5. Switch to monitor mode
ghostlink upstream monitor
iw dev gl-upstream info          # type should be "monitor"

# 6. Switch back to station
ghostlink upstream station
iw dev gl-upstream info          # type should be "managed"
```

Expected: Monitor mode toggle works, interface name stays `gl-upstream` throughout.

Troubleshoot if 88XXau not loading:
```bash
# Check DKMS build status
dkms status

# Check blacklist is in place
cat /etc/modprobe.d/ghostlink-realtek.conf

# Check for conflicting in-tree module
lsmod | grep -E "rtl8xxxu|rtw88"

# If conflicting: unload and re-probe
rmmod rtl8xxxu rtw88_8822bu rtw88_usb rtw88_8812au 2>/dev/null || true
modprobe 88XXau
```

---

## D — Scan Test

Goal: gl-upstream can see surrounding networks in monitor mode.

```bash
# Scan (auto-switches to monitor if needed)
ghostlink scan

# Or scan with longer duration
ghostlink scan gl-upstream --duration 20

# Alternative: raw airodump-ng
ghostlink upstream monitor
airodump-ng gl-upstream
# Ctrl-C after a few seconds
ghostlink upstream station
```

Expected: Table of SSIDs, BSSIDs, channels, and signal levels.

---

## E — Upstream Connect Test

Goal: gl-upstream connects to a real WiFi network and provides internet.

```bash
# 1. Switch to station mode
ghostlink upstream station

# 2. Connect to a known network
ghostlink upstream connect "YourSSID" "YourPassword"

# 3. Check IP assigned
ip -4 addr show gl-upstream
ip route show                    # gl-upstream should be default route

# 4. Test internet via gl-upstream
curl --interface gl-upstream https://ifconfig.me

# 5. Check upstream state
ghostlink upstream status
```

Expected: IP via DHCP, default route through gl-upstream, internet reachable.

---

## F — Hotspot Test

Goal: gl-hotspot broadcasts AP, clients can connect and get IPs.

```bash
# 1. Review config
grep -A10 '\[hotspot\]' /etc/ghostlink/ghostlink.conf

# 2. Start hotspot
ghostlink hotspot start

# 3. Verify services
ghostlink hotspot status
systemctl status hostapd --no-pager
systemctl status dnsmasq --no-pager

# 4. Check AP is broadcasting
iw dev gl-hotspot info

# 5. Connect a client device to "GhostNet" (or configured SSID)
#    Client should get 192.168.50.x address
#    Confirm from client: ping 192.168.50.1
```

Expected: hostapd active, AP visible to WiFi clients, DHCP leases assigned.

Troubleshoot:
```bash
journalctl -u hostapd -n 50
journalctl -u dnsmasq -n 50
cat /etc/hostapd/hostapd.conf
cat /etc/dnsmasq.conf
```

---

## G — NAT / Internet Sharing Test

Goal: Client connected to hotspot can reach internet through gl-upstream.

Prerequisites: Section E (upstream connected) and Section F (hotspot active) complete.

```bash
# 1. Verify NAT rules
ghostlink nat status

# 2. Apply / re-apply if needed
ghostlink nat start

# 3. From a client connected to the hotspot:
#    ping 8.8.8.8
#    curl https://ifconfig.me

# 4. Confirm forwarding is on
sysctl net.ipv4.ip_forward      # expect 1

# 5. Check iptables chains
iptables -L GHOSTLINK_FORWARD -v
iptables -t nat -L GHOSTLINK_NAT -v
```

Expected: Client traffic exits via gl-upstream; client sees internet-facing IP of RPi upstream.

---

## H — Doctor and Logs

Run these after the above tests and collect output before reporting issues.

```bash
ghostlink doctor

journalctl -u gl-network  -n 100 --no-pager
journalctl -u gl-identity -n 50  --no-pager
journalctl -u hostapd     -n 50  --no-pager
journalctl -u dnsmasq     -n 50  --no-pager

dkms status
lsmod | grep -E "88XXau|88x2bu|brcmfmac|rtl8xxxu|rtw88"
ip link
ip route
iptables -L -v --line-numbers
iptables -t nat -L -v
```

Paste the above output when filing issues.

---

## Quick Pass / Fail Summary

| Test | Command | Pass criteria |
|------|---------|---------------|
| mgmt IP | `ip -4 addr show gl-mgmt` | Shows IP |
| No default via mgmt | `ip route show default` | gl-mgmt not listed |
| gl-upstream exists | `ip link show gl-upstream` | Interface present |
| gl-hotspot exists | `ip link show gl-hotspot` | Interface present |
| 88XXau loaded | `lsmod \| grep 88XXau` | Module listed |
| Monitor mode | `ghostlink upstream monitor` | Returns 0, `iw` shows monitor |
| Scan | `ghostlink scan` | Table of APs appears |
| Upstream connect | `ghostlink upstream connect SSID PW` | IP assigned |
| Hotspot start | `ghostlink hotspot start` | hostapd active |
| NAT | `ghostlink nat status` | MASQUERADE rule present |
| Client internet | from client: `curl ifconfig.me` | Returns IP |
