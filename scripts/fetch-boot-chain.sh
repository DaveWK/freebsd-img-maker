#!/bin/sh
# Fetch the U-Boot-free boot chain for BOARD (r2s or rv2), oreboot bt0 ->
# OpenSBI -> EDK2, from the release assets of the board's ore-edk-boot-*
# repository named in config/boot-chain.env (latest release by default;
# BOOT_CHAIN_RELEASE=<tag> in the environment or the config pins one).
#
# The result is build/boot-chain/BOARD/{bt0.bin,next.img,SHA256SUMS,SOURCE}.
# BOOT_CHAIN_OUT=DIR uses an already built ore-edk-boot-* out/BOARD directory
# instead (for example a UEFI_VARS=nor build); its SHA256SUMS must verify.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
board=${1:?usage: fetch-boot-chain.sh r2s|rv2}
die() {
    echo "fetch-boot-chain: $*" >&2
    exit 1
}
case "$board" in r2s | rv2) ;; *) die "unknown board $board" ;; esac
release=${BOOT_CHAIN_RELEASE:-}
. "$here/config/boot-chain.env"
[ -z "$release" ] || BOOT_CHAIN_RELEASE=$release
dest=$here/build/boot-chain/$board

if [ -n "${BOOT_CHAIN_OUT:-}" ]; then
    from=$BOOT_CHAIN_OUT
    (cd "$from" && sha256sum --quiet -c SHA256SUMS) || die "$from/SHA256SUMS does not verify"
    source="prebuilt $(cd "$from" && sha256sum bt0.bin next.img | sha256sum | cut -d' ' -f1)"
    rm -rf "$dest"
    mkdir -p "$dest"
    cp "$from/bt0.bin" "$from/next.img" "$dest/"
else
    command -v curl >/dev/null || die 'curl is required to fetch the boot chain'
    case "$board" in
    r2s) repo=$BOOT_CHAIN_REPO_R2S ;;
    rv2) repo=$BOOT_CHAIN_REPO_RV2 ;;
    esac
    tag=$BOOT_CHAIN_RELEASE
    if [ "$tag" = latest ]; then
        url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") ||
            die "cannot resolve the latest release of $repo"
        tag=${url##*/}
        case "$url" in */releases/tag/*) ;; *) die "$repo has no release" ;; esac
    fi
    base=https://github.com/$repo/releases/download/$tag
    work=$dest.download
    rm -rf "$work"
    mkdir -p "$work"
    for f in SHA256SUMS bt0.bin next.img; do
        curl -fsSL -o "$work/$board-$f" "$base/$board-$f" || die "cannot download $base/$board-$f"
    done
    for f in bt0.bin next.img; do
        grep -q "^[0-9a-f]\{64\}  $board-$f\$" "$work/$board-SHA256SUMS" ||
            die "$board-SHA256SUMS of $repo $tag does not list $board-$f"
    done
    (cd "$work" && grep -E "  $board-(bt0\.bin|next\.img)\$" "$board-SHA256SUMS" | sha256sum --quiet -c) ||
        die "$repo $tag $board assets do not match $board-SHA256SUMS"
    rm -rf "$dest"
    mkdir -p "$dest"
    mv "$work/$board-bt0.bin" "$dest/bt0.bin"
    mv "$work/$board-next.img" "$dest/next.img"
    rm -rf "$work"
    source="$repo release $tag (UEFI variables in RAM)"
fi
(cd "$dest" && sha256sum bt0.bin next.img >SHA256SUMS)
printf '%s\n' "$source" >"$dest/SOURCE"
echo "boot chain for $board: $source"
cat "$dest/SHA256SUMS"
