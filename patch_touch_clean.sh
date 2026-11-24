#!/usr/bin/env bash
# ============================================================================
# patch_touch_clean.sh — Repack OrangeFox vendor_ramdisk01 onto a matching
# base vendor_boot.img (stock HyperOS / saiOS / AOSP) for Xiaomi 14T (degas).
#
# Preserves:
#   - vendor_ramdisk00 from MODBASE untouched (stock 6.1.157 modules + ROM's
#     first_stage_ramdisk/fstab.mt6897) so normal Android boot is unaffected.
#   - The freshly compiled vendor_ramdisk01 from OrangeFox untouched, including
#     init.recovery.mt6897.rc (MTP ConfigFS, AnyKernel3 /sbin/getprop, dynamic
#     Slot A/B symlinks, and MiTEE/KeyMint/Gatekeeper/Weaver/OMAPI decrypt),
#     recovery-only patched 6.1.157 xiaomi_touch_common.ko, and Goodix firmware.
#   - Exact 64 MiB (67,108,864 B) vendor_boot v4 layout with relocated AVB0/AVBf
#     footer when present in MODBASE (required for clean MT6897 / Fenrir LK boot).
#
# Optional env vars:
#   MODBASE=/path/to/base_vendor_boot.img
#   FRESH=/path/to/out/target/product/degas/vendor_boot.img
#   OUTIMG=/path/to/output_vendor_boot.img
#   DECRYPTED_DATA=1   Strip FBE/inlinecrypt flags from recovery.fstab /data
#                      (recommended for decrypted ROMs such as saiOS).
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${BUILD_TOP:-}" ]; then
    TOP="$BUILD_TOP"
elif [ -f "$SCRIPT_DIR/out/target/product/degas/vendor_boot.img" ]; then
    TOP="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/../../../out/target/product/degas/vendor_boot.img" ]; then
    TOP="$(cd "$SCRIPT_DIR/../../.." && pwd)"
else
    TOP="$SCRIPT_DIR"
fi

MODBASE="${MODBASE:-$SCRIPT_DIR/ofox_degas-vendor_boot.img}"
FRESH="${FRESH:-$TOP/out/target/product/degas/vendor_boot.img}"
OUTIMG="${OUTIMG:-$SCRIPT_DIR/ofox_degas-vendor_boot-clean.img}"
DECRYPTED_DATA="${DECRYPTED_DATA:-0}"

for cmd in lz4 cpio python3; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found" >&2; exit 1; }
done
for f in "$MODBASE" "$FRESH"; do
    [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
done

python3 - "$MODBASE" "$FRESH" "$OUTIMG" "$SCRIPT_DIR" "$DECRYPTED_DATA" <<'PYEOF'
import os, re, shutil, struct, subprocess, sys, tempfile
from pathlib import Path

modbase_p = Path(sys.argv[1])
fresh_p = Path(sys.argv[2])
out_p = Path(sys.argv[3])
dt_dir = Path(sys.argv[4])
decrypted_data = sys.argv[5] == "1"

def parse_vboot_v4(blob: bytes, label: str):
    if blob[:8] != b"VNDRBOOT":
        raise SystemExit(f"ERROR: {label} is not a VNDRBOOT image")
    _, hdr_ver, page_sz, _, _, ram_sz = struct.unpack_from("<8s5I", blob, 0)
    if hdr_ver != 4:
        raise SystemExit(f"ERROR: {label} header_version={hdr_ver} (expected 4)")
    _, _, hdr_sz, dtb_sz, _, vrt_sz, vrt_num, vrt_entry_sz, bootcfg_sz = struct.unpack_from("<I16sIIQIIII", blob, 2076)
    align = lambda n: (n + page_sz - 1) & ~(page_sz - 1)
    o_ram = align(hdr_sz)
    o_dtb = o_ram + align(ram_sz)
    o_vrt = o_dtb + align(dtb_sz)
    o_bc = o_vrt + align(vrt_sz)
    frags = []
    for i in range(vrt_num):
        fsz, foff, ftype = struct.unpack_from("<III", blob, o_vrt + i * vrt_entry_sz)
        frags.append((fsz, foff, ftype, blob[o_ram + foff : o_ram + foff + fsz]))
    return {
        "page_sz": page_sz, "hdr_sz": hdr_sz, "dtb_sz": dtb_sz,
        "vrt_sz": vrt_sz, "vrt_num": vrt_num, "vrt_entry_sz": vrt_entry_sz,
        "bootcfg_sz": bootcfg_sz, "o_ram": o_ram, "o_dtb": o_dtb, "o_vrt": o_vrt,
        "dtb": blob[o_dtb : o_dtb + dtb_sz],
        "vrt": bytearray(blob[o_vrt : o_vrt + vrt_sz]),
        "bootcfg": blob[o_bc : o_bc + bootcfg_sz],
        "frags": frags,
    }

base_bytes = modbase_p.read_bytes()
fresh_bytes = fresh_p.read_bytes()
base = parse_vboot_v4(base_bytes, "MODBASE")
fresh = parse_vboot_v4(fresh_bytes, "FRESH")

if base["vrt_num"] != 2:
    raise SystemExit(f"ERROR: MODBASE has {base['vrt_num']} ramdisk fragments (expected 2)")

# Locate recovery ramdisk (type=0x2) in FRESH, fallback to last fragment
rec_frag = None
for fsz, foff, ftype, fdata in fresh["frags"]:
    if ftype == 2:
        rec_frag = fdata
        break
if rec_frag is None:
    rec_frag = fresh["frags"][-1][3]

# Decompress and inspect/patch recovery ramdisk (vendor_ramdisk01)
with tempfile.TemporaryDirectory(prefix="ofox_repack_") as td:
    td = Path(td)
    rec_cpio = td / "rec.cpio"
    rec_dir = td / "rec_root"
    rec_dir.mkdir()
    subprocess.run(["lz4", "-d", "-c"], input=rec_frag, stdout=open(rec_cpio, "wb"), check=True)
    subprocess.run(["cpio", "-idm", "--no-absolute-filenames"], cwd=rec_dir, stdin=open(rec_cpio, "rb"), check=True, stderr=subprocess.DEVNULL)

    # Ensure recovery-only patched 6.1.157 touch module & Goodix firmware are present
    rec_ko = dt_dir / "recovery/root/lib/modules/xiaomi_touch_common.ko"
    if rec_ko.is_file():
        dst_ko = rec_dir / "lib/modules/xiaomi_touch_common.ko"
        dst_ko.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(rec_ko, dst_ko)
        os.chmod(dst_ko, 0o644)

    for fw_name in ("goodix_cfg_group_degas.bin", "goodix_firmware_degas.bin"):
        src_fw = None
        for cand in (
            dt_dir / "recovery/root/vendor/firmware" / fw_name,
            dt_dir / "recovery/root/lib/firmware" / fw_name,
            dt_dir / fw_name,
        ):
            if cand.is_file():
                src_fw = cand
                break
        if src_fw:
            for dst_sub in ("vendor/firmware", "lib/firmware"):
                dst_fw = rec_dir / dst_sub / fw_name
                dst_fw.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src_fw, dst_fw)
                os.chmod(dst_fw, 0o644)

    # Ensure degas_slot_symlinks.sh & degas_prepdecrypt.sh are executable
    for sh_name in ("degas_slot_symlinks.sh", "degas_prepdecrypt.sh"):
        sh_p = rec_dir / "system/bin" / sh_name
        if sh_p.is_file():
            os.chmod(sh_p, 0o755)

    # Sanity-check intact init.recovery.mt6897.rc
    init_rc = rec_dir / "init.recovery.mt6897.rc"
    if not init_rc.is_file():
        raise SystemExit("ERROR: init.recovery.mt6897.rc missing from freshly built recovery ramdisk!")

    # Optional decrypted /data adjustment for decrypted ROMs (e.g. saiOS)
    if decrypted_data:
        fstab_p = rec_dir / "system/etc/recovery.fstab"
        txt = fstab_p.read_text(encoding="utf-8")
        new_lines = []
        for l in txt.splitlines():
            if "/dev/block/by-name/userdata" in l and "/data" in l:
                for pat in (
                    r",inlinecrypt",
                    r",fileencryption=[^,\s]+",
                    r",keydirectory=[^,\s]+",
                    r",fsverity",
                    r",metadata_encryption=[^,\s]+",
                ):
                    l = re.sub(pat, "", l)
            new_lines.append(l)
        fstab_p.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
        print("  [+] Adjusted recovery.fstab /data for decrypted ROM (saiOS mode)")

    # Repack recovery ramdisk with root:root ownership & lz4 -l -12 --favor-decSpeed
    file_list = subprocess.check_output(["sh", "-c", "find . | sed 's|^\\./||' | grep -v '^\\.$' | sort"], cwd=rec_dir)
    cpio_out = subprocess.check_output(["cpio", "-H", "newc", "-o", "-R", "0:0"], cwd=rec_dir, input=file_list, stderr=subprocess.DEVNULL)
    new_f1_lz4 = subprocess.check_output(["lz4", "-l", "-12", "--favor-decSpeed", "-c"], input=cpio_out)

    # Keep base frag0 (vendor_ramdisk00) untouched; recompress with -12 ONLY if needed to fit 64 MiB
    f0_lz4 = base["frags"][0][3]
    page_sz = base["page_sz"]
    align = lambda n: (n + page_sz - 1) & ~(page_sz - 1)

    def calc_end(f0_len, f1_len):
        o_ram = base["o_ram"]
        o_dtb = o_ram + align(f0_len + f1_len)
        o_vrt = o_dtb + align(base["dtb_sz"])
        o_bc = o_vrt + align(base["vrt_sz"])
        return o_bc + align(base["bootcfg_sz"])

    avbf_idx = len(base_bytes) - 64
    has_avbf = len(base_bytes) == 67108864 and base_bytes[avbf_idx : avbf_idx + 4] == b"AVBf"
    avb0_sz = 0
    if has_avbf:
        _, old_vb_off, avb0_sz = struct.unpack_from(">QQQ", base_bytes, avbf_idx + 12)
        if base_bytes[old_vb_off : old_vb_off + 4] != b"AVB0":
            has_avbf = False

    limit = (avbf_idx - avb0_sz) if has_avbf else 67108864
    if calc_end(len(f0_lz4), len(new_f1_lz4)) > limit:
        print("  [*] Recompressing vendor_ramdisk00 with lz4 -l -12 for extra 64 MiB headroom...")
        f0_raw = subprocess.check_output(["lz4", "-d", "-c"], input=f0_lz4)
        f0_lz4 = subprocess.check_output(["lz4", "-l", "-12", "--favor-decSpeed", "-c"], input=f0_raw)

    new_f0_sz = len(f0_lz4)
    new_f1_sz = len(new_f1_lz4)
    new_ram_sz = new_f0_sz + new_f1_sz
    o_ram = base["o_ram"]
    new_o_dtb = o_ram + align(new_ram_sz)
    new_o_vrt = new_o_dtb + align(base["dtb_sz"])
    new_o_bc = new_o_vrt + align(base["vrt_sz"])
    new_end = new_o_bc + align(base["bootcfg_sz"])

    print(f"=== sizes ===")
    print(f"  ramdisk00 (base modules+fstab): {new_f0_sz} B ({new_f0_sz/1048576:.2f} MiB)")
    print(f"  ramdisk01 (OrangeFox recovery): {new_f1_sz} B ({new_f1_sz/1048576:.2f} MiB)")
    print(f"  payload end:                    {new_end} B ({new_end/1048576:.2f} MiB) | limit: {limit} B")
    if new_end > limit:
        raise SystemExit(f"ERROR: Image overflows 64 MiB vendor_boot partition by {new_end - limit} bytes!")

    out_len = 67108864 if has_avbf else new_end
    out_vb = bytearray(out_len)
    out_vb[: base["hdr_sz"]] = base_bytes[: base["hdr_sz"]]
    struct.pack_into("<I", out_vb, 24, new_ram_sz)
    out_vb[o_ram : o_ram + new_f0_sz] = f0_lz4
    out_vb[o_ram + new_f0_sz : o_ram + new_ram_sz] = new_f1_lz4
    out_vb[new_o_dtb : new_o_dtb + base["dtb_sz"]] = base["dtb"]
    vrt = bytearray(base["vrt"])
    struct.pack_into("<II", vrt, 0, new_f0_sz, 0)
    struct.pack_into("<II", vrt, base["vrt_entry_sz"], new_f1_sz, new_f0_sz)
    out_vb[new_o_vrt : new_o_vrt + base["vrt_sz"]] = vrt
    if base["bootcfg_sz"]:
        out_vb[new_o_bc : new_o_bc + base["bootcfg_sz"]] = base["bootcfg"]

    if has_avbf:
        out_vb[new_end : new_end + avb0_sz] = base_bytes[old_vb_off : old_vb_off + avb0_sz]
        out_vb[avbf_idx:] = base_bytes[avbf_idx:]
        struct.pack_into(">QQ", out_vb, avbf_idx + 12, new_end, new_end)
        print(f"  [+] Relocated AVB0 ({avb0_sz} B) + AVBf footer (exact 64 MiB = {len(out_vb)} B)")

    out_p.write_bytes(out_vb)
    print(f"=== DONE: {out_p} ({len(out_vb)} B) ===")
PYEOF
