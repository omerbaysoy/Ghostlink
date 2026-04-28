#!/usr/bin/env bash
# Profile helpers — source this, don't exec

PROFILES_FILE="/etc/ghostlink/device_profiles.json"

profile_keys() {
    jq -r 'keys[]' "$PROFILES_FILE"
}

profile_count() {
    jq 'length' "$PROFILES_FILE"
}

random_profile() {
    jq -r 'keys[]' "$PROFILES_FILE" | shuf -n1
}

profile_field() {
    local name="$1" field="$2"
    jq -r --arg n "$name" --arg f "$field" '.[$n][$f] // empty' "$PROFILES_FILE"
}

profile_oui() {
    profile_field "$1" "oui"
}

profile_hostname() {
    profile_field "$1" "hostname"
}

profile_vendor() {
    profile_field "$1" "vendor"
}

profile_model() {
    profile_field "$1" "model"
}

profile_exists() {
    jq -e --arg n "$1" '.[$n]' "$PROFILES_FILE" >/dev/null 2>&1
}

# Generate full MAC from OUI (XX:XX:XX) + 3 random bytes
generate_mac() {
    local oui="$1"
    local b4 b5 b6
    b4=$(printf '%02x' $((RANDOM % 256)))
    b5=$(printf '%02x' $((RANDOM % 256)))
    b6=$(printf '%02x' $((RANDOM % 256)))
    echo "${oui}:${b4}:${b5}:${b6}"
}
