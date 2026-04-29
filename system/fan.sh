#!/usr/bin/env bash
# PWM fan control daemon for Raspberry Pi 5
# Reads CPU temp from /sys, writes PWM to fan sysfs
# Exits cleanly on non-RPi5 hardware (no pwm1 sysfs nodes)

TEMP_PATH="/sys/class/thermal/thermal_zone0/temp"
FAN_PATH="/sys/class/hwmon/hwmon*/pwm1"
LOG_TAG="gl-fan"

# Guard: exit if there's no PWM fan sysfs node (not RPi5 or no case fan)
_has_pwm=false
for _f in /sys/class/hwmon/hwmon*/pwm1_enable; do
    [[ -f "$_f" ]] && { _has_pwm=true; break; }
done
if ! $_has_pwm; then
    echo "No PWM fan sysfs found — fan daemon not needed on this hardware" >&2
    exit 0
fi

temp_c() { awk '{printf "%d", $1/1000}' "$TEMP_PATH"; }

pwm_for_temp() {
    local t=$1
    if   [[ $t -lt 50 ]]; then echo 0
    elif [[ $t -lt 60 ]]; then echo 77    # ~30%
    elif [[ $t -lt 70 ]]; then echo 153   # ~60%
    else                        echo 255  # 100%
    fi
}

write_pwm() {
    local val=$1
    for f in $FAN_PATH; do
        [[ -f "$f" ]] && echo "$val" > "$f"
    done
}

# Enable manual PWM mode
for f in /sys/class/hwmon/hwmon*/pwm1_enable; do
    [[ -f "$f" ]] && echo 1 > "$f"
done

daemon() {
    logger -t "$LOG_TAG" "Fan control daemon started"
    while true; do
        local t pwm
        t=$(temp_c)
        pwm=$(pwm_for_temp "$t")
        write_pwm "$pwm"

        if [[ $t -ge 80 ]]; then
            logger -t "$LOG_TAG" "WARNING: CPU temp ${t}°C — thermal throttling imminent"
        fi

        sleep 5
    done
}

install() {
    mkdir -p /opt/ghostlink/system
    cp "$(realpath "$0")" /opt/ghostlink/system/fan.sh
    chmod +x /opt/ghostlink/system/fan.sh
}

case "${1:-daemon}" in
    daemon)  daemon  ;;
    install) install ;;
esac
