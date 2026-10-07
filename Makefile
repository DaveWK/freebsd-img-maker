# FreeBSD images for the OrangePi R2S and RV2 (SpacemiT K1), booted by the
# U-Boot-free chain released by ore-edk-boot-opi: oreboot bt0 -> OpenSBI -> EDK2.
#
#   make r2s        out/r2s/freebsd-r2s.img (+ boot0.bin, next.img)
#   make rv2        out/rv2/freebsd-rv2.img (bootable microSD image)
#   make freebsd    fetch, cross-build and stage FreeBSD only
#   make clean      remove out/ and the image work directories
#   make distclean  also remove build/ (source, objects, stage)
#   make mrproper   same as distclean (build/ holds the fetched boot chain too)
#   make help       list the targets
#
# The boot chain comes from the latest ore-edk-boot-* release for the board
# (config/boot-chain.env); BOOT_CHAIN_RELEASE=<tag> pins one, and
# BOOT_CHAIN_OUT=DIR uses a locally built ore-edk-boot-opi out/BOARD instead.
# ROOT_PASSWORD (default Riscv123), ROOT_MB (default: fit the files) and
# JOBS are passed through.

BOARDS := r2s rv2
STAGE_DONE := build/stage/BUILD

.PHONY: all help $(BOARDS) freebsd source boot-chain-% clean distclean mrproper

all: $(BOARDS)

help:
	@echo "r2s        out/r2s/freebsd-r2s.img (+ boot0.bin, next.img)"
	@echo "rv2        out/rv2/freebsd-rv2.img (bootable microSD image)"
	@echo "freebsd    fetch, cross-build and stage FreeBSD only"
	@echo "source     fetch the pinned FreeBSD source"
	@echo "clean      remove out/ and the image work directories"
	@echo "distclean  also remove build/ (source, objects, stage)"
	@echo "mrproper   same as distclean (build/ holds the fetched boot chain too)"

source:
	sh scripts/fetch-source.sh

$(STAGE_DONE):
	sh scripts/build-freebsd.sh

freebsd:
	sh scripts/build-freebsd.sh

boot-chain-%:
	sh scripts/fetch-boot-chain.sh $*

$(BOARDS): %: $(STAGE_DONE) boot-chain-%
	sh scripts/assemble-image.sh $*

clean:
	rm -rf out build/.image-*

distclean: clean
	rm -rf build

mrproper: distclean
