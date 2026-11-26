#!/system/bin/sh
# Create active-slot base symlinks (/dev/block/by-name/{boot,init_boot,...})
# so twrp.flags works identically on both Slot A and Slot B, and ensure
# /sbin/getprop exists for AnyKernel3 zips before recovery starts.

[ -e /sbin/getprop ] || ln /system/bin/toolbox_ramdisk /sbin/getprop 2>/dev/null

SUF=$(getprop ro.boot.slot_suffix)
if [ -z "$SUF" ]; then
    SUF=$(sed -n 's/.*androidboot\.slot_suffix[[:space:]]*=[[:space:]]*"\?\(_[ab]\).*/\1/p' /proc/bootconfig /proc/cmdline 2>/dev/null | head -n1)
fi
[ -z "$SUF" ] && SUF="_a"

for part in boot init_boot vendor_boot dtbo vbmeta vbmeta_system vbmeta_vendor; do
    src="/dev/block/by-name/${part}${SUF}"
    dst="/dev/block/by-name/${part}"
    if [ -e "$src" ]; then
        ln -sf "$src" "$dst" 2>/dev/null
    fi
done

exit 0
