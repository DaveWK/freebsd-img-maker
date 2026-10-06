#!/bin/sh
# Guarded transition for the documented R2S boot state.
# Requires pmicw/mmior/mmiow. May be called by r2s_cpu; not a cpufreq driver.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
fail() { echo "cpu-clock: $*" >&2; exit 1; }
rd() {
    value=$(mmior "$1" 1 | awk '/^0x/{print "0x" $2}')
    [ -n "$value" ] || fail "cannot read $1"
    printf '%s\n' "$value"
}
check() { [ "$(($(rd "$1")))" -eq "$(($2))" ] || fail "unexpected register $1 (wanted $2)"; }
voltage() { pmicw 0x48 | awk '/^reg /{print $4}'; }
show() {
    pmicw 0x48
    mmior 0xd4090124 3
    mmior 0xd4050010 1
    mmior 0xd4282b8c 2
    sysctl dev.spacemit_tsensor.0.temperature
}
case ${1:-show} in
show) show; exit 0 ;;
1600) ;;
*) fail 'usage: r2s-cpu-clock.sh [show|1600]' ;;
esac
[ "$(uname -s)" = FreeBSD ] && [ "$(uname -m)" = riscv ] ||
    fail 'requires the R2S FreeBSD riscv board'
case " $(sysctl -n hw.fdt.compatible) " in
    *' xunlong,orangepi-r2s '*) ;;
    *) fail 'device tree does not identify an Orange Pi R2S' ;;
esac
[ "$(id -u)" -eq 0 ] || fail 'requires root'
# Reject unfamiliar PLL programming, dividers, or a partially changed state.
check 0xd4090124 0x0050dd67
c0=$(rd 0xd4282b8c); c1=$(rd 0xd4282b90)
v=$(voltage)
if [ "$((c0))" -eq 583 ] && [ "$((c1))" -eq 583 ]; then
    [ "$v" = 0x6e ] || fail 'fast clock without the expected 1.05 V rail'
    check 0xd4090128 0x2; check 0xd409012c 0xc3eaaaab
    [ "$(($(rd 0xd4050010) & 0x20000000))" -ne 0 ] || fail 'PLL3 unlocked'
    echo 'Already at the validated 1.6 GHz register state'; show; exit 0
fi
[ "$((c0))" -eq 576 ] && [ "$((c1))" -eq 576 ] || fail 'unexpected cluster clocks'
check 0xd4090128 0; check 0xd409012c 0x43eaaaab
case $v in 0x50|0x6e) ;; *) fail "unexpected buck1 voltage selector $v" ;; esac
# Voltage MUST precede PLL/mux changes. Readback failure stops the sequence.
pmicw 0x48 =0x6e
[ "$(voltage)" = 0x6e ] || fail 'buck1 did not reach the 1.05 V selector'
sleep 1
mmiow 0xd4090128 0x2
check 0xd4090128 0x2
mmiow 0xd409012c 0xc3eaaaab
check 0xd409012c 0xc3eaaaab
tries=0
while [ "$(($(rd 0xd4050010) & 0x20000000))" -eq 0 ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 5 ] || fail 'PLL3 failed to lock; clusters left on slow parent'
    sleep 1
done
for addr in 0xd4282b8c 0xd4282b90; do
    mmiow "$addr" 0x247
    mmiow "$addr" 0x1247
    check "$addr" 0x247
done
echo 'Validated 1.6 GHz state applied (buck1 1.05 V, PLL3 locked)'
show
