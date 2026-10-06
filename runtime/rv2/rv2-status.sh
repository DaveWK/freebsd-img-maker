#!/bin/sh
# Read-only evidence collection; no storage writes, tuning, jobs or reboots.
set -eu
date -u
uname -a
cat /etc/freebsd-img-maker
sysctl hw.model hw.ncpu hw.physmem kern.boottime
sysctl -a | grep -E 'dev\.(cpu|spacemit_tsensor)|hw\.clockrate' || true
mount
df -h
ifconfig -a
netstat -i -b -d
pciconf -lv || echo 'PCI enumeration failed; inspect dmesg below.' >&2
camcontrol devlist || echo 'CAM enumeration failed; inspect dmesg below.' >&2
usbconfig list || echo 'USB enumeration failed; inspect dmesg below.' >&2
dmesg
