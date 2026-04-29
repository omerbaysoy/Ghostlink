#!/usr/bin/env bash
# Management identity protection guard — source this, don't exec directly.
#
# Provides:
#   role_iface <role>            → prints actual OS interface for logical role (mgmt/upstream/hotspot/aux)
#   is_trusted_iface <iface>     → returns 0 if iface is connected to a trusted SSID
#   is_protected_iface <iface>   → returns 0 if iface must not be spoofed
#   should_protect_hostname      → returns 0 if hostname must not be changed
#   mgmt_hostname                → prints the configured management hostname
#   is_trusted_ssid              → returns 0 if current mgmt SSID is in trusted list
#   mgmt_protection_summary      → prints human-readable protection status

MGMT_CONF="${GHOSTLINK_CONF:-/etc/ghostlink/ghostlink.conf}"
MGMT_MAP="${GHOSTLINK_MAP:-/var/lib/ghostlink/interfaces.map}"

_mgmt_ini_get() {
    local section="$1" key="$2" default="${3:-}"
    local val
    val=$(awk -F'=' "/^\[${section}\]/{s=1} s && /^${key}=/{print \$2; exit}" \
          "$MGMT_CONF" 2>/dev/null)
    echo "${val:-$default}"
}

# Resolve logical role (mgmt/upstream/hotspot/aux or gl-mgmt/gl-upstream/...) to actual OS interface.
# Reads /var/lib/ghostlink/interfaces.map written by classify.sh.
# Falls back to the gl-* name itself if the map is absent (e.g. rename_interfaces=true).
role_iface() {
    local role="${1:-}"
    # Normalize: strip gl- prefix for lookup key
    local key="gl-${role#gl-}"
    if [[ -f "$MGMT_MAP" ]]; then
        local val
        val=$(grep "^${key}=" "$MGMT_MAP" 2>/dev/null | cut -d= -f2)
        if [[ -n "$val" ]]; then
            echo "$val"
            return
        fi
    fi
    # Fallback: if the interface named key exists, use it directly
    if [[ -d "/sys/class/net/$key" ]]; then
        echo "$key"
        return
    fi
    # Nothing found — return empty
    echo ""
}

# Returns 0 if the given interface is connected to any trusted SSID.
is_trusted_iface() {
    local iface="${1:-}"
    [[ -z "$iface" ]] && return 1
    local trusted_raw
    trusted_raw=$(_mgmt_ini_get management trusted_ssids "")
    [[ -z "$trusted_raw" ]] && return 1
    local current_ssid
    current_ssid=$(iwgetid "$iface" -r 2>/dev/null || echo "")
    [[ -z "$current_ssid" ]] && return 1
    IFS=',' read -ra ssid_list <<< "$trusted_raw"
    for raw_ssid in "${ssid_list[@]}"; do
        local ssid="${raw_ssid#"${raw_ssid%%[![:space:]]*}"}"
        ssid="${ssid%"${ssid##*[![:space:]]}"}"
        [[ "$current_ssid" == "$ssid" ]] && return 0
    done
    return 1
}

# Returns 0 if the specified interface must not be MAC-spoofed.
# Protection rules (any one match = protected):
#   1. Interface is the configured management interface AND protect_gl_mgmt=true
#   2. Interface is connected to a trusted SSID (Mainframe-16, Ghostlink-NET, etc.)
#   3. Interface's IP is the local endpoint of an active SSH session
#   4. Interface is carrying the default route (gateway interface)
is_protected_iface() {
    local iface="$1"
    [[ -z "$iface" ]] && return 1

    # Rule 1: management interface is protected by default
    local protect_mgmt
    protect_mgmt=$(_mgmt_ini_get management protect_gl_mgmt "true")
    if [[ "$protect_mgmt" == "true" ]]; then
        local mgmt_iface
        mgmt_iface=$(_mgmt_ini_get network mgmt_interface "gl-mgmt")
        local mgmt_actual
        mgmt_actual=$(role_iface "mgmt")
        if [[ "$iface" == "gl-mgmt" || "$iface" == "$mgmt_iface" || ( -n "$mgmt_actual" && "$iface" == "$mgmt_actual" ) ]]; then
            return 0
        fi
    fi

    # Rule 2: any interface connected to a trusted SSID is protected
    if is_trusted_iface "$iface" 2>/dev/null; then
        return 0
    fi

    # Rule 3 & 4: IP-based protection — only for non-operational interfaces
    case "$iface" in
        gl-upstream|gl-hotspot|gl-aux) ;;  # Operational interfaces skip IP checks
        *)
            local ip
            ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1];exit}')
            if [[ -n "$ip" ]]; then
                # Rule 3: SSH session endpoint
                if _is_ssh_local_ip "$ip"; then
                    return 0
                fi
                # Rule 4: default route interface
                if _is_default_route_iface "$iface"; then
                    return 0
                fi
            fi
            ;;
    esac

    return 1
}

# Returns 0 if hostname must not be changed.
# Protected when protect_hostname=true OR allow_hostname_spoof is not explicitly true.
should_protect_hostname() {
    local protect_hostname
    protect_hostname=$(_mgmt_ini_get management protect_hostname "true")
    [[ "$protect_hostname" == "true" ]] && return 0

    local allow_spoof
    allow_spoof=$(_mgmt_ini_get management allow_hostname_spoof "false")
    [[ "$allow_spoof" != "true" ]] && return 0

    return 1
}

# Returns the configured management hostname (default: Ghostlink)
mgmt_hostname() {
    _mgmt_ini_get management hostname "Ghostlink"
}

# Returns 0 if the management interface's current SSID is in the trusted list
is_trusted_ssid() {
    local mgmt_iface
    mgmt_iface=$(_mgmt_ini_get network mgmt_interface "gl-mgmt")
    local actual_mgmt
    actual_mgmt=$(role_iface "mgmt")
    # Try actual resolved interface first, then config value, then gl-mgmt
    for try_iface in "$actual_mgmt" "$mgmt_iface" "gl-mgmt"; do
        [[ -z "$try_iface" ]] && continue
        if is_trusted_iface "$try_iface" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Prints a human-readable protection summary (used by status.sh and doctor)
mgmt_protection_summary() {
    local mgmt_iface
    mgmt_iface=$(_mgmt_ini_get network mgmt_interface "gl-mgmt")
    local upstream_iface
    upstream_iface=$(_mgmt_ini_get network upstream_interface "gl-upstream")
    local aux_iface
    aux_iface=$(_mgmt_ini_get network aux_interface "gl-aux")

    local protect_mgmt protect_hostname allow_mac_spoof allow_hostname_spoof
    protect_mgmt=$(_mgmt_ini_get management protect_gl_mgmt "true")
    protect_hostname=$(_mgmt_ini_get management protect_hostname "true")
    allow_mac_spoof=$(_mgmt_ini_get management allow_mgmt_mac_spoof "false")
    allow_hostname_spoof=$(_mgmt_ini_get management allow_hostname_spoof "false")

    local cfg_hostname
    cfg_hostname=$(mgmt_hostname)

    local active_hostname
    active_hostname=$(hostname 2>/dev/null || echo "unknown")

    local trusted_ssid_status="not connected / no trusted SSIDs configured"
    if is_trusted_ssid 2>/dev/null; then
        local current_ssid
        current_ssid=$(iwgetid "$mgmt_iface" -r 2>/dev/null || echo "")
        trusted_ssid_status="connected to trusted SSID: $current_ssid"
    fi

    echo "  Management hostname : $cfg_hostname"
    echo "  Active hostname     : $active_hostname"
    echo "  Trusted SSID        : $trusted_ssid_status"
    echo ""
    echo "  Interface protection:"

    for iface in "$mgmt_iface" "$upstream_iface" "$aux_iface" "gl-hotspot"; do
        local prot_label
        if is_protected_iface "$iface" 2>/dev/null; then
            prot_label="PROTECTED (no MAC spoof)"
        else
            prot_label="spoofable"
        fi
        printf "    %-14s  %s\n" "$iface" "$prot_label"
    done

    echo ""
    echo "  Hostname protection : $([ "$protect_hostname" == "true" ] && echo "enabled" || echo "disabled")"
    echo "  allow_mgmt_mac_spoof: $allow_mac_spoof"
    echo "  allow_hostname_spoof: $allow_hostname_spoof"
}

# Internal: returns 0 if the given IP is the local endpoint of an SSH connection
_is_ssh_local_ip() {
    local ip="$1"
    ss -tnp 2>/dev/null | awk '/ESTAB.*sshd/{print $4}' | \
        awk -F: '{print $1}' | grep -qF "$ip"
}

# Internal: returns 0 if the given interface carries the default route
_is_default_route_iface() {
    local iface="$1"
    ip route show default 2>/dev/null | grep -q "dev $iface"
}
