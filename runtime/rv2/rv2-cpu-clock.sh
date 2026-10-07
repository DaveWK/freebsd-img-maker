#!/bin/sh
# Guarded transition for the documented RV2 boot state.
# RV2 only: helpers use /dev/iic0. Called at boot by rv2_cpu.
# show/status are read-only; 1600 sets the validated fixed operating point.
set -eu
PATH=${RV2_CLOCK_HELPERS:-/usr/local/libexec/rv2-clock}:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
fail() {
    echo "cpu-clock: $*" >&2
    exit 1
}
rd() {
    raw=$(mmior "$1" 1) || fail "cannot read $1"
    value=$(printf '%s\n' "$raw" | awk '
        $1 ~ /^0x[0-9a-fA-F]+:$/ && $2 ~ /^[0-9a-fA-F]+$/ && NF == 2 {
            print "0x" $2
        }')
    [ -n "$value" ] || fail "cannot read $1"
    case $value in *[!0-9a-fA-Fx]*) fail "invalid readback for $1" ;; esac
    printf '%s\n' "$value"
}
check() {
    actual=$(rd "$1") || exit 1
    [ "$((actual))" -eq "$(($2))" ] || fail "unexpected register $1 (wanted $2)"
}
voltage() {
    raw=$(pmicw 0x48) || fail 'cannot read buck1'
    value=$(printf '%s\n' "$raw" | awk '/^reg 0x48 = 0x[0-9a-fA-F]+$/ {print $4}')
    [ -n "$value" ] || fail 'invalid buck1 readback'
    printf '%s\n' "$value"
}
verify_fast() {
    check 0xd4090124 0x0050dd67
    check 0xd4090128 0x2
    check 0xd409012c 0xc3eaaaab
    check 0xd4282b8c 0x247
    check 0xd4282b90 0x247
    v=$(voltage)
    [ "$v" = 0x6e ] || fail 'fast clock without the expected 1.05 V rail'
    lock=$(rd 0xd4050010)
    [ "$((lock & 0x20000000))" -ne 0 ] || fail 'PLL3 unlocked'
}
show() {
    pmicw 0x48
    mmior 0xd4090124 3
    mmior 0xd4050010 1
    mmior 0xd4282b8c 2
    sysctl dev.spacemit_tsensor.0.temperature || true
}
mode=${1:-show}
case $mode in
show | status | 1600) ;;
*) fail 'usage: rv2-cpu-clock [show|status|1600]' ;;
esac
[ "$(uname -s)" = FreeBSD ] && [ "$(uname -m)" = riscv ] ||
    fail 'requires the RV2 FreeBSD riscv board'
case " $(sysctl -n hw.fdt.compatible) " in
*' xunlong,orangepi-rv2 '*) ;;
*) fail 'device tree does not identify an Orange Pi RV2' ;;
esac
[ "$(id -u)" -eq 0 ] || fail 'requires root'
case $mode in
show)
    show
    exit 0
    ;;
status)
    verify_fast
    echo 'RV2: both clusters at 1.6 GHz, buck1 1.05 V, PLL3 locked'
    exit 0
    ;;
esac
# Reject unfamiliar PLL programming, dividers, or a partially changed state.
check 0xd4090124 0x0050dd67
c0=$(rd 0xd4282b8c)
c1=$(rd 0xd4282b90)
v=$(voltage)
if [ "$((c0))" -eq 583 ] && [ "$((c1))" -eq 583 ]; then
    verify_fast
    echo 'Already at the validated 1.6 GHz register state'
    show
    exit 0
fi
[ "$((c0))" -eq 576 ] && [ "$((c1))" -eq 576 ] || fail 'unexpected cluster clocks'
check 0xd4090128 0
check 0xd409012c 0x43eaaaab
case $v in 0x50 | 0x6e) ;; *) fail "unexpected buck1 voltage selector $v" ;; esac
# Voltage MUST precede PLL/mux changes. Readback failure stops the sequence.
pmicw 0x48 =0x6e
[ "$(voltage)" = 0x6e ] || fail 'buck1 did not reach the 1.05 V selector'
sleep 1
mmiow 0xd4090128 0x2
check 0xd4090128 0x2
mmiow 0xd409012c 0xc3eaaaab
check 0xd409012c 0xc3eaaaab
tries=0
while :; do
    lock=$(rd 0xd4050010)
    [ "$((lock & 0x20000000))" -eq 0 ] || break
    tries=$((tries + 1))
    [ "$tries" -lt 5 ] || fail 'PLL3 failed to lock; clusters left on slow parent'
    sleep 1
done
for addr in 0xd4282b8c 0xd4282b90; do
    mmiow "$addr" 0x247
    mmiow "$addr" 0x1247
    check "$addr" 0x247
done
verify_fast
echo 'Validated 1.6 GHz state applied (buck1 1.05 V, PLL3 locked)'
show
