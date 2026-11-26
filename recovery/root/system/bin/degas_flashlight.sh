#!/system/bin/sh
# Toggle Xiaomi/MediaTek LM3644 dual-LED torch via flashlight_core sysfs.
# torchbrightness takes total torch current in mA (0 = off, 1..380 = on).

NODE="/sys/class/flashlight_core/flashlight/torchbrightness"

if [ ! -e "$NODE" ]; then
    insmod /vendor/lib/modules/mtk_bp_thl.ko 2>/dev/null
    insmod /vendor/lib/modules/mtk_peak_power_budget.ko 2>/dev/null
    insmod /vendor/lib/modules/flashlight.ko 2>/dev/null
    insmod /vendor/lib/modules/lm3644.ko 2>/dev/null
fi

[ -w "$NODE" ] || exit 1

case "$1" in
    1|on)
        echo 200 > "$NODE"
        ;;
    0|off)
        echo 0 > "$NODE"
        ;;
    *)
        if grep -q '\[0\]' "$NODE" 2>/dev/null; then
            echo 200 > "$NODE"
        else
            echo 0 > "$NODE"
        fi
        ;;
esac
