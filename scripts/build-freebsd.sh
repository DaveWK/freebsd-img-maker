#!/bin/sh
# Cross-build FreeBSD for the K1 boards on Linux, unprivileged, and stage it.
#
#   build/obj/            MAKEOBJDIRPREFIX (world, kernels, bootstrapped
#                         makefs/mkimg/pwd_mkdb used by assemble-image.sh)
#   build/stage/world/    installworld + distribution, -DNO_ROOT with METALOG
#   build/stage/r2s/      installkernel KERNCONF=R2SPROD, -DNO_ROOT with METALOG
#   build/stage/rv2/      installkernel KERNCONF=RV2PROD, -DNO_ROOT with METALOG
#   build/stage/dtb/      k1-orangepi-r2s.dtb and k1-orangepi-rv2.dtb
#
# The userland targets the SpacemiT X60 (rv64gcv_zba_zbb_zbs, see
# config/k1-world-make.conf); kernels use their configuration's ISA.
# JOBS defaults to the number of CPUs. The steps are incremental (--no-clean);
# remove build/obj for a clean build.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
src=${FREEBSD_SRC:-$here/build/freebsd-src}
obj=${OBJ:-$here/build/obj}
stage=${STAGE:-$here/build/stage}
jobs=${JOBS:-$(nproc)}
die() {
    echo "build-freebsd: $*" >&2
    exit 1
}

[ "$(uname -s)" = Linux ] || die 'run on Linux'
[ "$(id -u)" -ne 0 ] || die 'run unprivileged; nothing here needs root'
for t in clang ld.lld llvm-ar llvm-nm llvm-objcopy python3 git; do
    command -v "$t" >/dev/null || die "missing $t"
done
sh "$here/scripts/fetch-source.sh" >/dev/null

mkdir -p "$obj" "$here/build/host-tools"
# The bootstrap uses BSD date -ur EPOCH; translate it for GNU date.
cat >"$here/build/host-tools/date" <<'EOF'
#!/bin/sh
# Translate BSD epoch syntax for the Linux bootstrap host only.
if [ "$1" = "-ur" ]; then
    shift
    epoch=$1
    shift
    exec /bin/date -u -d "@$epoch" "$@"
fi
exec /bin/date "$@"
EOF
chmod 0755 "$here/build/host-tools/date"
printf '.include "%s"\n.include "%s"\n' "$here/config/k1-world-make.conf" "$here/config/linux-host.mk" \
    >"$here/build/world-make.conf"
printf '.include "%s"\n' "$here/config/linux-host.mk" >"$here/build/kernel-make.conf"

make_k1() {
    conf=$1
    shift
    (cd "$src" && env MAKEOBJDIRPREFIX="$obj" SRCCONF=/dev/null __MAKE_CONF="$conf" \
        PATH="$here/build/host-tools:/usr/bin:/bin" \
        python3 tools/build/make.py --no-clean --cross-bindir=/usr/bin -j"$jobs" \
        TARGET=riscv TARGET_ARCH=riscv64 NEWVERS_ARGS=-r \
        -DWITH_REPRODUCIBLE_BUILD -DWITH_REPRODUCIBLE_PATHS \
        -DWITH_DISK_IMAGE_TOOLS_BOOTSTRAP "$@" </dev/null)
}

echo '==> buildworld'
make_k1 "$here/build/world-make.conf" buildworld
echo '==> buildkernel R2SPROD RV2PROD'
make_k1 "$here/build/kernel-make.conf" KERNCONF='R2SPROD RV2PROD' buildkernel

# Fresh stage directories; installworld and installkernel write METALOGs.
rm -rf "$stage"
mkdir -p "$stage/world" "$stage/r2s" "$stage/rv2" "$stage/dtb"
echo '==> installworld distribution'
make_k1 "$here/build/world-make.conf" -DNO_ROOT DESTDIR="$stage/world" installworld distribution
for board in r2s rv2; do
    kernconf=$(echo "$board" | tr '[:lower:]' '[:upper:]')PROD
    echo "==> installkernel $kernconf"
    make_k1 "$here/build/kernel-make.conf" -DNO_ROOT DESTDIR="$stage/$board" \
        KERNCONF="$kernconf" installkernel
    env MACHINE=riscv sh "$src/sys/tools/fdt/make_dtb.sh" "$src/sys" \
        "$src/sys/contrib/device-tree/src/riscv/spacemit/k1-orangepi-$board.dts" "$stage/dtb"
done
for f in world/METALOG world/boot/loader.efi r2s/METALOG r2s/boot/kernel/kernel \
    rv2/METALOG rv2/boot/kernel/kernel dtb/k1-orangepi-r2s.dtb dtb/k1-orangepi-rv2.dtb; do
    [ -s "$stage/$f" ] || die "missing $stage/$f"
done
{
    echo "freebsd_commit=$(git -C "$src" rev-parse HEAD)"
    echo "freebsd_tree=$(git -C "$src" rev-parse 'HEAD^{tree}')"
    echo "world_make_conf_sha256=$(sha256sum "$here/config/k1-world-make.conf" | cut -d' ' -f1)"
    echo "compiler=$(clang --version | sed -n 1p)"
} >"$stage/BUILD"
echo "FreeBSD staged in $stage"
