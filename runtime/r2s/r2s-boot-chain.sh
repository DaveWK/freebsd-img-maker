#!/bin/sh
# Install or check the R2S boot chain shipped in this image:
#   /usr/local/share/k1-boot-chain/boot0.bin -> eMMC boot0 (BootROM descriptor + bt0)
#   /usr/local/share/k1-boot-chain/next.img  -> eMMC boot1 (OpenSBI + EDK2 FIT)
#
#   r2s-boot-chain status           read-only comparison
#   r2s-boot-chain install --yes    back up boot0/boot1, write, read back
#
# Backups of both hardware partitions go to /var/backups/r2s-boot-chain-DATE/.
# If the board does not start afterwards, download mode is the recovery
# path (see the README of ore-edk-boot-opi).
set -eu
share=/usr/local/share/k1-boot-chain
boot0=/dev/mmcsd0boot0
boot1=/dev/mmcsd0boot1
die() {
    echo "r2s-boot-chain: $*" >&2
    exit 1
}

[ -c "$boot0" ] && [ -c "$boot1" ] || die "no eMMC boot partitions ($boot0, $boot1)"
(cd "$share" && sha256 -c "$(awk '$2=="boot0.bin"{print $1}' SHA256SUMS)" boot0.bin >/dev/null &&
    sha256 -c "$(awk '$2=="next.img"{print $1}' SHA256SUMS)" next.img >/dev/null) ||
    die "$share does not match its SHA256SUMS"

# installed PARTITION FILE: does the start of PARTITION hold FILE?
installed() {
    size=$(stat -f %z "$2")
    [ "$(dd if="$1" bs=512 count=$((size / 512)) 2>/dev/null | sha256 -q)" = "$(sha256 -q "$2")" ]
}
state() {
    if installed "$1" "$2"; then echo installed; else echo different; fi
}

case "${1:-status}" in
status)
    echo "boot0 (descriptor + bt0): $(state "$boot0" "$share/boot0.bin")"
    echo "boot1 (OpenSBI + EDK2):   $(state "$boot1" "$share/next.img")"
    ;;
install)
    [ "${2:-}" = --yes ] || die 'this rewrites the eMMC boot partitions; run: r2s-boot-chain install --yes'
    [ "$(id -u)" -eq 0 ] || die 'run as root'
    backup=/var/backups/r2s-boot-chain-$(date +%Y%m%d-%H%M%S)
    mkdir -p "$backup"
    dd if="$boot0" of="$backup/boot0.raw" bs=1m status=none
    dd if="$boot1" of="$backup/boot1.raw" bs=1m status=none
    (cd "$backup" && sha256 boot0.raw boot1.raw >SHA256)
    echo "backed up boot0 and boot1 to $backup"
    flags=$(sysctl -n kern.geom.debugflags)
    trap 'sysctl kern.geom.debugflags="$flags" >/dev/null' EXIT HUP INT TERM
    sysctl kern.geom.debugflags=$((flags | 16)) >/dev/null
    # The FIT first, so a failed bt0 write still leaves an old bt0 that
    # finds a complete next stage.
    dd if="$share/next.img" of="$boot1" bs=1m conv=notrunc status=none
    sync
    installed "$boot1" "$share/next.img" || die 'boot1 read-back failed'
    dd if="$share/boot0.bin" of="$boot0" bs=512 conv=notrunc status=none
    sync
    installed "$boot0" "$share/boot0.bin" || die 'boot0 read-back failed'
    echo 'boot chain installed and read back; it runs on the next boot'
    ;;
*)
    die "usage: r2s-boot-chain status | install --yes"
    ;;
esac
