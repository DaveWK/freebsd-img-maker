# FreeBSD images for the OrangePi R2S and RV2 (SpacemiT K1), booted by the
# U-Boot-free chain from ore-edk-boot-opi: oreboot bt0 -> OpenSBI -> EDK2.
#
#   make r2s        out/r2s/freebsd-r2s.img (+ boot0.bin, next.img)
#   make rv2        out/rv2/freebsd-rv2.img (bootable microSD image)
#   make freebsd    fetch, cross-build and stage FreeBSD only
#   make clean      remove out/ and the image work directories
#   make distclean  also remove build/ (source, objects, stage)
#
# BOOT_CHAIN_OUT=DIR uses a prebuilt ore-edk-boot-opi out/BOARD directory.
# UEFI_VARS=nor (RV2 only) keeps UEFI variables in the SPI NOR instead of RAM;
# the build warns because EDK2 then erases NOR 0x2a0000-0x360000 on first boot.
# ROOT_PASSWORD (default Riscv123), ROOT_MB (default: fit the files) and
# JOBS are passed through.

BOARDS := r2s rv2
STAGE_DONE := build/stage/BUILD

.PHONY: all $(BOARDS) freebsd source boot-chain-% clean distclean

all: $(BOARDS)

source:
	sh scripts/fetch-source.sh

$(STAGE_DONE):
	sh scripts/build-freebsd.sh

freebsd:
	sh scripts/build-freebsd.sh

boot-chain-%:
	sh scripts/build-boot-chain.sh $*

$(BOARDS): %: $(STAGE_DONE) boot-chain-%
	sh scripts/assemble-image.sh $*

clean:
	rm -rf out build/.image-*

distclean: clean
	rm -rf build
