#!/system/bin/sh
# Point /dev/degas_haptics_node_ to whichever I2C haptic IC probed (AW8697/AW86927 or Sih6887)
for d in \
    /sys/devices/platform/11d00000.i2c/i2c-0/0-005a \
    /sys/devices/platform/11d00000.i2c/i2c-0/0-006b \
    /sys/class/leds/vibrator; do
    if [ -e "$d/activate" ] && [ -e "$d/duration" ]; then
        ln -sfn "$d" /dev/degas_haptics_node_
        exit 0
    fi
done
exit 0
