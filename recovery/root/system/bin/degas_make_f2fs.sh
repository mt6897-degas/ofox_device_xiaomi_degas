#!/system/bin/sh
#
# degas_make_f2fs.sh — installed as /system/bin/make_f2fs (wrapping make_f2fs.real).
#
# On Android 12+ with metadata encryption (dm-default-key), TWRP/OrangeFox
# unmounts /data before running make_f2fs, but leaves /dev/block/mapper/userdata
# mapped over /dev/block/sdc92, causing make_f2fs to fail with:
#   "Error: In use by the system!"
# Also, stale keys in /metadata/vold/metadata_encryption prevent clean boot
# or re-encryption after Format Data.
#
# When invoked against userdata (raw device or its dm-default-key mapper),
# cleanly tear down the dm mapping, wipe stale encryption/snapshot metadata,
# rewrite any deleted dm-* target arg to the underlying userdata block device,
# and exec /system/bin/make_f2fs.real.

REAL=/system/bin/make_f2fs.real
LOG=/tmp/recovery.log
log() { echo "I:degas_make_f2fs: $*" >> "$LOG"; }

UD_LINK=/dev/block/by-name/userdata
UD_REAL=$(readlink -f "$UD_LINK" 2>/dev/null || realpath "$UD_LINK" 2>/dev/null || echo "$UD_LINK")
UD_BASE=$(basename "$UD_REAL")

is_userdata_dm() {
    dev="$1"
    [ -n "$dev" ] || return 1
    case "$dev" in
        /dev/block/mapper/userdata|/dev/block/mapper/userdata*) return 0 ;;
    esac
    rdev=$(readlink -f "$dev" 2>/dev/null || realpath "$dev" 2>/dev/null || echo "$dev")
    bdev=$(basename "$rdev")
    case "$bdev" in
        dm-*)
            if [ -e "/sys/block/$bdev/slaves/$UD_BASE" ]; then
                return 0
            fi
            ;;
    esac
    return 1
}

is_userdata_arg() {
    arg="$1"
    case "$arg" in
        "$UD_LINK"|"$UD_REAL"|*/userdata) return 0 ;;
    esac
    is_userdata_dm "$arg" && return 0
    return 1
}

TARGET_IS_USERDATA=0
for a in "$@"; do
    if is_userdata_arg "$a"; then
        TARGET_IS_USERDATA=1
        break
    fi
done

if [ "$TARGET_IS_USERDATA" -eq 0 ]; then
    exec "$REAL" "$@"
fi

log "Format Data detected (userdata=$UD_REAL); releasing dm-default-key and stale metadata"

# Ensure nothing keeps /data or its dm device busy
for mp in /sdcard /data/media/0 /data/media /data; do
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null
done

# Tear down any dm device holding userdata (e.g. dm-default-key 'userdata')
teardown_dm() {
    for dm_dir in /sys/block/dm-*; do
        [ -d "$dm_dir" ] || continue
        if [ -e "$dm_dir/slaves/$UD_BASE" ]; then
            dm_name=$(cat "$dm_dir/dm/name" 2>/dev/null)
            if [ -n "$dm_name" ]; then
                log "deleting dm device '$dm_name' ($(basename "$dm_dir"))"
                /system/bin/dmctl delete "$dm_name" >> "$LOG" 2>&1
            fi
        fi
    done
    # Fallback by canonical name
    if [ -e /dev/block/mapper/userdata ]; then
        /system/bin/dmctl delete userdata >> "$LOG" 2>&1
    fi
}

i=0
while [ "$i" -lt 6 ]; do
    teardown_dm
    still_held=0
    for dm_dir in /sys/block/dm-*; do
        [ -e "$dm_dir/slaves/$UD_BASE" ] && still_held=1
    done
    [ "$still_held" -eq 0 ] && [ ! -e /dev/block/mapper/userdata ] && break
    sleep 0.2
    i=$((i + 1))
done

# Wipe stale metadata encryption keys, checkpoints, and OTA snapshots
META_MOUNTED_BY_US=0
if ! grep -q ' /metadata ' /proc/mounts 2>/dev/null; then
    mkdir -p /metadata
    if mount -t f2fs -o rw,noatime,nosuid,nodev /dev/block/by-name/metadata /metadata 2>/dev/null; then
        META_MOUNTED_BY_US=1
    fi
fi

if grep -q ' /metadata ' /proc/mounts 2>/dev/null; then
    log "clearing /metadata/vold/{metadata_encryption,checkpoint} and /metadata/ota/snapshots"
    rm -rf /metadata/vold/metadata_encryption/* 2>/dev/null
    rm -rf /metadata/vold/checkpoint/* 2>/dev/null
    rm -rf /metadata/ota/snapshots/* 2>/dev/null
    sync
    if [ "$META_MOUNTED_BY_US" -eq 1 ]; then
        umount /metadata 2>/dev/null || umount -l /metadata 2>/dev/null
    fi
fi

# Rebuild positional args: rewrite any deleted dm-* / mapper/userdata path to UD_REAL
n=$#
idx=0
while [ "$idx" -lt "$n" ]; do
    cur="$1"
    shift
    if is_userdata_dm "$cur"; then
        log "rewriting target '$cur' -> '$UD_REAL'"
        set -- "$@" "$UD_REAL"
    else
        set -- "$@" "$cur"
    fi
    idx=$((idx + 1))
done

exec "$REAL" "$@"
