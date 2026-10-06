# Linux-only host-tool compatibility for accepted source snapshots.
# libmagic/config.h detects byteswap.h through __FreeBSD_version, which is not
# defined while compiling the Linux mkmagic tool. glibc provides byteswap.h.
# Keep this out of target world/kernel compilation. Upstream 8929675e11c0 adds
# swap.c to the tool, but accepted board source pins predate that change.
.if ${.MAKE.OS} == "Linux" && ${.CURDIR:T} == "libmagic" && make(build-tools)
CFLAGS+= -DHAVE_BYTESWAP_H=1
.endif
