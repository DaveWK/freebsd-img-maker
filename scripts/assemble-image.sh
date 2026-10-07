#!/bin/sh
# Assemble the FreeBSD disk image for BOARD (r2s or rv2), unprivileged.
#
# Inputs: the staged world and BOARD kernel from build-freebsd.sh, the boot
# chain from fetch-boot-chain.sh, and boards/BOARD + runtime/BOARD. Every
# file added or changed is recorded with owner and mode in the METALOG, from
# which the bootstrapped makefs builds the root-owned UFS2 root and FAT16
# ESP; mkimg writes the GPT image. Nothing here runs as root, mounts
# anything, or executes a RISC-V binary.
#
# Login: root with password ROOT_PASSWORD (default Riscv123) on the console
# and over SSH. No SSH keys are installed; sshd makes host keys on first boot.
#
# Output: out/BOARD/freebsd-BOARD.img, the boot chain's bt0.bin and next.img,
# for the R2S boot0.bin (descriptor + bt0 for eMMC boot0), and SHA256SUMS.
set -eu
umask 022
here=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
board=${1:?usage: assemble-image.sh r2s|rv2}
src=${FREEBSD_SRC:-$here/build/freebsd-src}
obj=${OBJ:-$here/build/obj}
stage=${STAGE:-$here/build/stage}
chain=$here/build/boot-chain/$board
out=${OUT_DIR:-$here/out}/$board
root_password=${ROOT_PASSWORD:-Riscv123}
root_mb=${ROOT_MB:-0}
esp_mb=64
die() {
    echo "assemble-image: $*" >&2
    exit 1
}

case "$board" in r2s | rv2) ;; *) die "unknown board $board" ;; esac
[ "$(uname -s)" = Linux ] || die 'run on Linux'
[ "$(id -u)" -ne 0 ] || die 'run unprivileged; nothing here needs root'
# shellcheck source=/dev/null # the board is chosen at run time
. "$here/boards/$board/board.conf"
. "$here/config/freebsd.env"
for t in python3 openssl sha256sum clang ld.lld; do
    command -v "$t" >/dev/null || die "missing $t"
done
tools=$obj$(CDPATH='' cd -- "$src" && pwd -P)/riscv.riscv64/tmp/legacy/bin
for t in makefs mkimg pwd_mkdb; do
    [ -x "$tools/$t" ] || die "missing $tools/$t; run scripts/build-freebsd.sh"
done
for f in world/METALOG world/boot/loader.efi "$board/METALOG" "$board/boot/kernel/kernel" "dtb/$DTB" BUILD; do
    [ -s "$stage/$f" ] || die "missing $stage/$f; run scripts/build-freebsd.sh"
done
(cd "$chain" && sha256sum --quiet -c SHA256SUMS) || die "no verified boot chain in $chain; run scripts/fetch-boot-chain.sh $board"

mkdir -p "$here/build" "$out"
work=$(mktemp -d "$here/build/.image-$board.XXXXXX")
# KEEP_WORK=yes keeps the staged root and METALOG.image for inspection.
[ "${KEEP_WORK:-no}" = yes ] || trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
root=$work/root
efi=$work/efi
overrides=$work/METALOG.overrides
removals=$work/METALOG.removals
: >"$overrides"
: >"$removals"

# Record PATH (relative to the root) with type, mode and owner; the last
# record of a path wins over installworld's.
meta() {
    printf './%s type=%s uname=%s gname=%s mode=%s\n' "$1" "$2" "${4:-root}" "${5:-wheel}" "$3" >>"$overrides"
}
# mkdir -p as root: every new component is root:wheel 0755.
mkdir_root() {
    path=
    old_ifs=$IFS
    IFS=/
    for part in $1; do
        path=${path:+$path/}$part
        if [ ! -d "$root/$path" ]; then
            mkdir "$root/$path"
            meta "$path" dir 0755
        fi
    done
    IFS=$old_ifs
}
# install -m MODE SRC DEST (DEST relative to the root), owned root:wheel.
install_root() {
    install -m "$1" "$2" "$root/$3"
    meta "$3" file "$1"
}

# [1/7] World and BOARD kernel, with their METALOGs.
echo "==> $board: staging world and $KERNCONF"
mkdir "$root"
cp -a --reflink=auto "$stage/world/." "$root/"
cp -a --reflink=auto "$stage/$board/." "$root/"
rm -f "$root/METALOG"
cat "$stage/world/METALOG" "$stage/$board/METALOG" >"$work/METALOG.base"
for path in etc/master.passwd etc/ttys etc/ssh/sshd_config boot/loader.efi boot/kernel/kernel; do
    grep -q "^\./$path " "$work/METALOG.base" || die "METALOG lacks ./$path"
done

# [2/7] Board configuration.
mkdir_root boot/dtb
mkdir_root boot/efi
install_root 0644 "$stage/dtb/$DTB" "boot/dtb/$DTB"
install_root 0644 "$here/boards/$board/loader.conf" boot/loader.conf
install_root 0644 "$here/boards/$board/rc.conf" etc/rc.conf
install_root 0644 "$here/boards/$board/fstab" etc/fstab
install_root 0644 "$here/boards/$board/sysctl.conf" etc/sysctl.conf
mkdir_root "usr/local/share/$board-freebsd"
install_root 0644 "$here/boards/$board/smte-performance.json" "usr/local/share/$board-freebsd/smte-performance.json"

# [3/7] Board runtime: CPU clock, MAC addresses, devd rules. The C helpers
# are cross-compiled against the staged world.
mkdir_root usr/local/sbin
mkdir_root usr/local/bin
mkdir_root usr/local/etc/rc.d
mkdir_root etc/devd
cc_target() {
    clang --target=riscv64-unknown-freebsd16.0 --sysroot="$root" -fuse-ld=lld \
        -O2 -Wall -Wextra -Werror "$@"
}
rt=$here/runtime/$board
case "$board" in
r2s)
    for name in pmicw mmior mmiow; do
        cc_target -march=rv64gcv_zba_zbb_zbs -mtune=spacemit-x60 "$rt/$name.c" -o "$root/usr/local/sbin/$name"
        meta "usr/local/sbin/$name" file 0755
    done
    install_root 0755 "$rt/r2s-cpu-clock.sh" usr/local/sbin/r2s-cpu-clock.sh
    install_root 0755 "$rt/smte-macs.sh" usr/local/sbin/smte-macs.sh
    install_root 0755 "$rt/r2s_cpu" usr/local/etc/rc.d/r2s_cpu
    install_root 0755 "$rt/smte_macs.rc" usr/local/etc/rc.d/smte_macs
    install_root 0755 "$rt/r2s-boot-chain.sh" usr/local/sbin/r2s-boot-chain
    install_root 0644 "$rt/devd-r2s-nomatch.conf" etc/devd/r2s-nomatch.conf
    ;;
rv2)
    mkdir_root usr/local/libexec/rv2-clock
    for name in pmicw mmior mmiow; do
        cc_target -march=rv64gc -mabi=lp64d "$rt/rv2-clock/$name.c" -o "$root/usr/local/libexec/rv2-clock/$name"
        meta "usr/local/libexec/rv2-clock/$name" file 0755
    done
    install_root 0755 "$rt/rv2-cpu-clock.sh" usr/local/sbin/rv2-cpu-clock
    install_root 0755 "$rt/rv2_cpu" usr/local/etc/rc.d/rv2_cpu
    install_root 0755 "$rt/rv2-status.sh" usr/local/bin/rv2-status
    install_root 0644 "$rt/devd-rv2-nomatch.conf" etc/devd/rv2-nomatch.conf
    ;;
esac

# [4/7] The boot chain this image was made with, for reinstalling it.
share=usr/local/share/k1-boot-chain
mkdir_root "$share"
case "$board" in
r2s)
    python3 "$here/scripts/k1-bootinfo.py" emmc-boot0 "$chain/bt0.bin" "$work/boot0.bin"
    install_root 0644 "$work/boot0.bin" "$share/boot0.bin"
    ;;
rv2)
    install_root 0644 "$chain/bt0.bin" "$share/bt0.bin"
    ;;
esac
install_root 0644 "$chain/next.img" "$share/next.img"
(cd "$root/$share" && sha256sum -- * >"$work/chain.sums" && mv "$work/chain.sums" SHA256SUMS)
meta "$share/SHA256SUMS" file 0644
install_root 0644 "$chain/SOURCE" "$share/SOURCE"

# [5/7] Login: root with a password, on the console and over SSH. No keys:
# no authorized_keys and no host keys (sshd generates them on first boot).
cat "$here/config/sshd_config.append" >>"$root/etc/ssh/sshd_config"
for directive in PermitRootLogin PasswordAuthentication KbdInteractiveAuthentication PermitEmptyPasswords; do
    [ "$(grep -c "^$directive " "$root/etc/ssh/sshd_config")" = 1 ] || die "sshd_config sets $directive more than once"
done
root_hash=$(printf '%s\n' "$root_password" | openssl passwd -6 -stdin)
printf '%s\n' "$root_hash" | grep -Eq '^[$]6[$][./0-9A-Za-z]{1,16}[$][./0-9A-Za-z]{86}$' ||
    die 'openssl did not produce a SHA-512 crypt hash'
ROOT_HASH=$root_hash awk -F: -v OFS=: '$1 == "root" { $2 = ENVIRON["ROOT_HASH"]; n++ } { print } END { exit n != 1 }' \
    "$root/etc/master.passwd" >"$work/master.passwd"
cat "$work/master.passwd" >"$root/etc/master.passwd"
"$tools/pwd_mkdb" -i -p -d "$root/etc" "$root/etc/master.passwd"
for key in "$root"/etc/ssh/ssh_host_*; do
    [ -e "$key" ] || continue
    rm -f "$key"
done
grep -o '^\./etc/ssh/ssh_host_[^ ]*' "$work/METALOG.base" >>"$removals" || :
grep -o '^\./root/\.ssh/authorized_keys[^ ]*' "$work/METALOG.base" >>"$removals" || :
# Serial getty on the UART console, root allowed to log in there.
sed 's/^ttyu0.*/ttyu0   "\/usr\/libexec\/getty 3wire"   vt100   onifconsole  secure/' \
    "$root/etc/ttys" >"$work/ttys"
cat "$work/ttys" >"$root/etc/ttys"
grep -q '^ttyu0 .*onifconsole  secure$' "$root/etc/ttys" || die 'ttyu0 getty line not set'
# First boot: growfs fills the medium, sshd makes host keys.
: >"$root/firstboot"
meta firstboot file 0644
# newfs makes the root's .snap directory; makefs does not.
mkdir_root .snap
meta .snap dir 0775 root operator

# [6/7] Identity of everything in the image.
sha() { sha256sum "$1" | cut -d' ' -f1; }
{
    echo "board=$board"
    echo "kernconf=$KERNCONF"
    cat "$stage/BUILD"
    echo "freebsd_repo=$FREEBSD_REPO"
    echo "freebsd_upstream_commit=$FREEBSD_UPSTREAM_COMMIT"
    commit=$(git -C "$here" rev-parse --verify -q HEAD || echo none)
    git -C "$here" diff --quiet HEAD -- 2>/dev/null || commit=$commit-dirty
    echo "img_maker_commit=$commit"
    echo "boot_chain=$(cat "$chain/SOURCE")"
    echo "bt0_sha256=$(sha "$chain/bt0.bin")"
    echo "next_img_sha256=$(sha "$chain/next.img")"
    echo "kernel_sha256=$(sha "$root/boot/kernel/kernel")"
    echo "loader_sha256=$(sha "$root/boot/loader.efi")"
    echo "dtb_sha256=$(sha "$root/boot/dtb/$DTB")"
    echo "built_utc=$(date -u +%FT%TZ)"
} >"$work/build-info"
install_root 0644 "$work/build-info" etc/freebsd-img-maker

# Merge the METALOGs: a path keeps its first position and its last record;
# removed paths are dropped.
python3 - "$work/METALOG.base" "$overrides" "$removals" "$work/METALOG.image" <<'PY'
import sys
base, overrides, removals, out = sys.argv[1:]
gone = {l.strip() for l in open(removals) if l.strip()}
lines = {}
for name in (base, overrides):
    for line in open(name):
        line = line.rstrip('\n')
        if not line or line.startswith('#'):
            continue
        path = line.split(' ', 1)[0]
        if path in gone:
            continue
        lines[path] = line  # dict keeps the first insertion position
open(out, 'w').write('#mtree 2.0\n' + ''.join(l + '\n' for l in lines.values()))
PY

# [7/7] Filesystems and the GPT image.
used_mb=$(du -sm --apparent-size "$root" | cut -f1)
if [ "$root_mb" = 0 ]; then
    # Content plus a third and 512 MiB, in 256 MiB steps; growfs fills the
    # medium on first boot.
    root_mb=$(((used_mb * 4 / 3 + 512 + 255) / 256 * 256))
fi
echo "==> $board: UFS2 root ${root_mb} MiB (${used_mb} MiB of files)"
(cd "$root" && "$tools/makefs" -t ffs -B little -D -Z -N "$root/etc" -s "${root_mb}m" \
    -o version=2,softupdates=1,label="$ROOT_LABEL",bsize=32768,fsize=4096 \
    -o density=8192,minfree=8,optimization=time \
    "$work/root.ufs" "$work/METALOG.image")
mkdir -p "$efi/EFI/BOOT"
install -m 0444 "$root/boot/loader.efi" "$efi/EFI/BOOT/BOOTRISCV64.EFI"
"$tools/makefs" -t msdos -s "${esp_mb}m" \
    -o fat_type=16,media_descriptor=248,volume_label="$ESP_VOLUME" \
    "$work/efi.fat" "$efi"
image=$work/freebsd-$board.img
case "$MEDIA" in
emmc)
    "$tools/mkimg" -s gpt \
        -p "efi/$ESP_LABEL:=$work/efi.fat:1m" \
        -p "freebsd-ufs/$ROOT_LABEL:=$work/root.ufs:$((1 + esp_mb))m" \
        -o "$image"
    root_part=2 esp_part=1
    ;;
sd)
    # boot1 at 4 MiB is where bt0 finds the next stage by name; the
    # descriptor and both bt0 copies go in front of it.
    "$tools/mkimg" -s gpt \
        -p "hifive-bbl/boot1:=$chain/next.img:4m" \
        -p "efi/$ESP_LABEL:=$work/efi.fat:8m" \
        -p "freebsd-ufs/$ROOT_LABEL:=$work/root.ufs:$((8 + esp_mb))m" \
        -o "$image"
    python3 "$here/scripts/k1-bootinfo.py" sd-install "$image" "$chain/bt0.bin"
    root_part=3 esp_part=2
    ;;
esac
rm -f "$work/root.ufs" "$work/efi.fat"

# Read-back checks in place of fsck: GPT labels, the UFS2 superblock magic,
# the FAT media byte and, on the SD card, boot1's contents.
python3 - "$image" "$root_part" "$ROOT_LABEL" "$esp_part" "$ESP_LABEL" "$MEDIA" "$chain/next.img" <<'PY'
import struct, sys
image, root_part, root_label, esp_part, esp_label, media, next_img = sys.argv[1:]
f = open(image, 'rb')
f.seek(512)
hdr = f.read(92)
assert hdr[:8] == b'EFI PART', 'no GPT'
lba, count, size = struct.unpack_from('<QII', hdr, 72)
def part(i):
    f.seek(lba * 512 + (i - 1) * size)
    e = f.read(size)
    start, end = struct.unpack_from('<QQ', e, 32)
    name = e[56:128].decode('utf-16-le').rstrip('\0')
    return start * 512, (end - start + 1) * 512, name
start, _, name = part(int(root_part))
assert name == root_label, f'root partition is labelled {name}'
f.seek(start + 65536 + 1372)
assert f.read(4) == struct.pack('<I', 0x19540119), 'no UFS2 superblock'
start, _, name = part(int(esp_part))
assert name == esp_label, f'ESP is labelled {name}'
f.seek(start + 21)
assert f.read(1) == b'\xf8', 'ESP media descriptor is not 0xf8'
if media == 'sd':
    start, length, name = part(1)
    assert (name, start) == ('boot1', 4 << 20), f'partition 1 is {name} at {start}'
    want = open(next_img, 'rb').read()
    f.seek(start)
    assert f.read(len(want)) == want, 'boot1 does not hold next.img'
print('image layout verified')
PY

cp "$work/build-info" "$work/freebsd-$board.img.info"
case "$board" in
r2s) cp "$work/boot0.bin" "$work/boot0.bin.out" ;;
esac
rm -f "$out/freebsd-$board.img" "$out/freebsd-$board.img.info" "$out/boot0.bin" "$out/bt0.bin" "$out/next.img" "$out/SHA256SUMS"
mv "$image" "$out/freebsd-$board.img"
mv "$work/freebsd-$board.img.info" "$out/freebsd-$board.img.info"
case "$board" in
r2s) mv "$work/boot0.bin.out" "$out/boot0.bin" ;;
esac
cp "$chain/bt0.bin" "$chain/next.img" "$out/"
(cd "$out" && sha256sum -- * >"$work/SHA256SUMS" && mv "$work/SHA256SUMS" SHA256SUMS && cat SHA256SUMS)
echo "==> $board: $out/freebsd-$board.img"
