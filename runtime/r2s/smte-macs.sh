#!/bin/sh
# Assign the R2S's real MAC addresses to smte0/smte1 from the ONIE TLV EEPROM.
#
# The two SpacemiT EMACs have no MAC storage of their own, so if_smte falls back
# to ether_gen_addr() and they get a fresh random 58:9c:fc:... address on every
# boot.  The board's AT24C02 at i2c2 0x50 holds an ONIE TLV record with the MAC
# base and count for exactly this purpose; the two RTL8125s read theirs from
# their own EEPROMs and already come up correct.
#
# TLV layout: "TlvInfo\0" + version(1) + total_len(2), then type(1) len(1) value.
#   0x24 = MAC base (6 bytes)   0x2a = number of MACs (2 bytes)
EEP=${EEP:-/dev/icee0}
IFACES="smte0 smte1"

[ -e "$EEP" ] || {
    echo "smte-macs: $EEP absent (i2c/EEPROM not attached)" >&2
    exit 1
}

# Split hexdump's space-separated hex bytes into positional arguments.
# shellcheck disable=SC2046
set -- $(dd if="$EEP" bs=1 count=64 2>/dev/null | hexdump -v -e '1/1 "%02x "')
[ "$1$2$3$4$5$6$7" = "546c76496e666f" ] || {
    echo "smte-macs: no TlvInfo header" >&2
    exit 1
}

# walk the TLVs starting at offset 11 (shift off the 11-byte header)
shift 11
base=""
count=0
while [ $# -ge 2 ]; do
    t=$1
    l=$(printf '%d' "0x$2")
    shift 2
    [ $# -ge "$l" ] || break
    case "$t" in
    24) base=$(printf '%s:%s:%s:%s:%s:%s' "$1" "$2" "$3" "$4" "$5" "$6") ;;
    2a) count=$((0x$1 * 256 + 0x$2)) ;;
    fe) break ;;
    esac
    i=0
    while [ $i -lt "$l" ]; do
        shift
        i=$((i + 1))
    done
done

[ -n "$base" ] || {
    echo "smte-macs: no MAC base (TLV 0x24) in EEPROM" >&2
    exit 1
}

oui=${base%:*}
last=${base##*:}
n=0
for ifc in $IFACES; do
    [ $n -lt "$count" ] || break
    mac=$(printf '%s:%02x' "$oui" $((0x$last + n)))
    cur=$(ifconfig "$ifc" 2>/dev/null | awk '/ether/{print $2}')
    if [ -z "$cur" ]; then
        n=$((n + 1))
        continue
    fi
    if [ "$cur" != "$mac" ]; then
        ifconfig "$ifc" ether "$mac" && echo "smte-macs: $ifc $cur -> $mac"
    fi
    n=$((n + 1))
done
