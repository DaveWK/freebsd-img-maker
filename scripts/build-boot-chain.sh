#!/bin/sh
# Build the U-Boot-free boot chain for BOARD (r2s or rv2) from the pinned
# ore-edk-boot-opi submodule: oreboot bt0 -> OpenSBI -> EDK2.
#
# The result is build/boot-chain/BOARD/{bt0.bin,next.img,SHA256SUMS,SOURCE}.
# BOOT_CHAIN_OUT=DIR uses an already built ore-edk-boot-opi out/BOARD
# directory (or an unpacked release) instead of building; its SHA256SUMS
# must verify.
#
# UEFI_VARS=ram (default) keeps EDK2's UEFI variables in RAM. On the RV2,
# UEFI_VARS=nor keeps them in the SPI NOR at 0x2a0000-0x360000; EDK2 erases
# and formats that range on first boot when it holds no variable store.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
board=${1:?usage: build-boot-chain.sh r2s|rv2}
die() {
    echo "build-boot-chain: $*" >&2
    exit 1
}
case "$board" in r2s | rv2) ;; *) die "unknown board $board" ;; esac
uefi_vars=${UEFI_VARS:-ram}
case "$uefi_vars" in
ram) ;;
nor)
    [ "$board" = rv2 ] || die 'UEFI_VARS=nor is only for the RV2 (the R2S has no SPI NOR)'
    cat >&2 <<'WARN'
WARNING: UEFI_VARS=nor. The RV2 image's EDK2 will keep UEFI variables in the
SPI NOR at 0x2a0000-0x360000 and ERASES and formats that range on first boot
when it holds no variable store. Firmware there (for example the vendor's) is
destroyed. Back up the NOR before booting this image.
WARN
    ;;
*) die "UEFI_VARS must be ram or nor, not $uefi_vars" ;;
esac
export UEFI_VARS="$uefi_vars"
dest=$here/build/boot-chain/$board

if [ -n "${BOOT_CHAIN_OUT:-}" ]; then
    from=$BOOT_CHAIN_OUT
    source="prebuilt $(cd "$from" && sha256sum bt0.bin next.img | sha256sum | cut -d' ' -f1) (UEFI_VARS as built)"
else
    chain=$here/boot-chain
    [ -f "$chain/Makefile" ] || die 'boot-chain submodule missing; run: git submodule update --init boot-chain'
    commit=$(git -C "$here" ls-tree HEAD boot-chain | awk '{print $3}')
    [ -z "$commit" ] || [ "$(git -C "$chain" rev-parse HEAD)" = "$commit" ] ||
        die "boot-chain is not at the pinned commit $commit; run: git submodule update boot-chain"
    make -C "$chain" submodules
    make -C "$chain" "$board"
    from=$chain/out/$board
    source="ore-edk-boot-opi $(git -C "$chain" rev-parse HEAD) UEFI_VARS=$uefi_vars"
fi
(cd "$from" && sha256sum --quiet -c SHA256SUMS) || die "$from/SHA256SUMS does not verify"
rm -rf "$dest"
mkdir -p "$dest"
cp "$from/bt0.bin" "$from/next.img" "$dest/"
(cd "$dest" && sha256sum bt0.bin next.img >SHA256SUMS)
printf '%s\n' "$source" >"$dest/SOURCE"
echo "boot chain for $board: $source"
cat "$dest/SHA256SUMS"
