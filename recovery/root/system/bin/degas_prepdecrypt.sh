#!/system/bin/sh
#
# degas_prepdecrypt.sh — make KeyMint see the installed Android's OS version and
# patch levels, then let init start the TEE stack (crypto.ready=1).
#
# Why: the stock libkeymint.so reads ro.build.version.release,
# ro.build.version.security_patch and ro.vendor.build.security_patch. The
# MiTEE KeyMint TA rejects a key blob whose version/patch is newer than these
# (INVALID_KEY_BLOB) and asks to *upgrade* a blob that is older — an upgrade
# makes vold rewrite the key, after which Android could no longer use it.
# So the values must never be higher than what Android's KeyMint uses.
#
# Values come from the on-device build.prop files (system/vendor of the
# active slot), i.e. what KeyMint sees when it starts during Android boot,
# before any root module rewrites props at post-fs-data.
#
# Fail-closed: if anything cannot be read or set, crypto.ready is NOT set and
# the TEE stack is not started.
#
# Read-only: system and vendor are mounted read-only and unmounted again.

LOG=/tmp/recovery.log
log() { echo "I:degas_prepdecrypt: $*" >> "$LOG"; }
err() { echo "E:degas_prepdecrypt: $*" >> "$LOG"; }

SUF=$(getprop ro.boot.slot_suffix)
SYS=/tmp/prepdecrypt_system
VEN=/tmp/prepdecrypt_vendor

mount_ro() {
	mkdir -p "$2"
	mount -t erofs -o ro "$1" "$2" 2>/dev/null || \
	mount -t ext4 -o ro,noload "$1" "$2" 2>/dev/null
}

cleanup() {
	umount "$SYS" 2>/dev/null || umount -l "$SYS" 2>/dev/null
	umount "$VEN" 2>/dev/null || umount -l "$VEN" 2>/dev/null
	rmdir "$SYS" "$VEN" 2>/dev/null
}

prop_from() { grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2-; }

log "slot suffix '$SUF'"

# Wait briefly for dm-linear logical partition mapper nodes if recovery just created them
w=0
while [ "$w" -lt 15 ]; do
	[ -e "/dev/block/mapper/system$SUF" ] && [ -e "/dev/block/mapper/vendor$SUF" ] && break
	sleep 0.2
	w=$((w + 1))
done

if ! mount_ro "/dev/block/mapper/system$SUF" "$SYS"; then
	err "cannot mount system$SUF read-only; TEE stack NOT started"
	cleanup; exit 1
fi
if ! mount_ro "/dev/block/mapper/vendor$SUF" "$VEN"; then
	err "cannot mount vendor$SUF read-only; TEE stack NOT started"
	cleanup; exit 1
fi

SYSPROP="$SYS/system/build.prop"
[ -f "$SYSPROP" ] || SYSPROP="$SYS/build.prop"

REL=$(prop_from ro.build.version.release "$SYSPROP")
SPL=$(prop_from ro.build.version.security_patch "$SYSPROP")
VSPL=$(prop_from ro.vendor.build.security_patch "$VEN/build.prop")

# Match userdata filename encryption cipher to the installed ROM before
# crypto.ready=1 (libfscrypt calls ReadDefaultFstab after crypto.ready=1):
# HyperOS/saiOS use aes-256-cts; AOSP Android 17 ROMs (EvoX/Halcyon) use aes-256-hctr2.
if grep -q "aes-256-hctr2" "$VEN/build.prop" "$VEN/etc"/fstab* 2>/dev/null; then
	if sed 's/aes-256-xts:aes-256-cts/aes-256-xts:aes-256-hctr2/g' /system/etc/recovery.fstab > /tmp/recovery.fstab.tmp; then
		cat /tmp/recovery.fstab.tmp > /system/etc/recovery.fstab
		rm -f /tmp/recovery.fstab.tmp
		log "detected aes-256-hctr2 in vendor; updated recovery.fstab"
	fi
fi
cleanup

log "from build.prop: release='$REL' security_patch='$SPL' vendor_security_patch='$VSPL'"
if [ -z "$REL" ] || [ -z "$SPL" ] || [ -z "$VSPL" ]; then
	err "missing value(s); TEE stack NOT started"
	exit 1
fi

set_prop() {
	resetprop "$1" "$2"
	if [ "$(getprop "$1")" != "$2" ]; then
		err "failed to set $1='$2' (now '$(getprop "$1")'); TEE stack NOT started"
		exit 1
	fi
	log "$1=$2"
}

set_prop ro.build.version.release "$REL"
set_prop ro.build.version.security_patch "$SPL"
set_prop ro.vendor.build.security_patch "$VSPL"

setprop crypto.ready 1
log "crypto.ready=1"
exit 0
