# freebsd-img-maker

FreeBSD images for the OrangePi R2S and OrangePi RV2, which use the SpacemiT K1 SoC. U-Boot is not used: the images boot through the chain from [ore-edk-boot-opi](https://github.com/DaveWK/ore-edk-boot-opi):

    BootROM -> oreboot bt0 (DRAM) -> OpenSBI -> EDK2 (UEFI) -> FreeBSD loader.efi -> kernel

| Image | Medium | Kernel | Contents |
|---|---|---|---|
| `make r2s` | eMMC (8 GB) | `R2SPROD` | `freebsd-r2s.img` for the eMMC user area, plus `boot0.bin` and `next.img` for the eMMC boot partitions and `bt0.bin` for download mode |
| `make rv2` | microSD | `RV2PROD` | `freebsd-rv2.img`, a complete bootable card image |

Status:

- R2S: installed with fastboot and booted to login with SSH (October 2026). The FreeBSD kernel at the current pin also boots on it.
- RV2: the image builds and its layout is checked, but it has not been boot-tested on hardware yet.

## Login

- User: `root`
- Password: `Riscv123`

SSH is enabled and accepts root password logins. The serial console allows root too. Change the password after the first login with `passwd`.

The images contain no SSH keys: no `authorized_keys` and no host keys. sshd generates host keys on first boot.

Every Ethernet port asks for DHCP. On first boot, `growfs` expands the root filesystem to fill the medium.

## Building

Builds run on Linux (Fedora), unprivileged. FreeBSD is cross-built with its own `tools/build/make.py`. Disk images are made with the bootstrapped `makefs` and `mkimg` from a METALOG, so nothing is mounted and nothing runs as root.

    git clone --recurse-submodules https://github.com/DaveWK/freebsd-img-maker.git
    cd freebsd-img-maker
    make r2s rv2

Requirements:

- FreeBSD: `clang`, `lld`, `llvm` (`llvm-ar`, `llvm-nm`, `llvm-objcopy`), `python3`, `git`, `openssl`.
- Boot chain: the tools listed in ore-edk-boot-opi's README (RISC-V GCC, Rust, `dtc`, `mkimage`).
- To skip building the boot chain, point `BOOT_CHAIN_OUT` at a built or released ore-edk-boot-opi `out/<board>` directory, for example `make rv2 BOOT_CHAIN_OUT=/path/to/out/rv2`.

The first build takes a few hours, most of it the FreeBSD world. The steps are:

1. `scripts/fetch-source.sh` fetches the pinned FreeBSD commit (`config/freebsd.env`), checks its tree hash, and applies `patches/` (currently none).
2. `scripts/build-freebsd.sh` runs `buildworld`, then `buildkernel` for `R2SPROD` and `RV2PROD`. It stages `installworld`, `distribution`, both kernels and both DTBs into `build/stage/`.
3. `scripts/build-boot-chain.sh <board>` builds bt0 and the OpenSBI+EDK2 FIT from the pinned `boot-chain` submodule.
4. `scripts/assemble-image.sh <board>` adds the board configuration, runtime helpers, login settings and boot chain, then writes the image to `out/<board>/`.

Tuning:

- `JOBS` sets build parallelism.
- `ROOT_MB` fixes the root filesystem size; by default the size fits the files plus headroom.
- `ROOT_PASSWORD` sets a different root password.
- `UEFI_VARS=nor` (RV2 only) keeps UEFI variables in the SPI NOR instead of RAM. The build warns about it; see the RV2 section below.

## What is in the images

- FreeBSD 16-CURRENT from the `OpiK1` branch of [DaveWK/freebsd-src](https://github.com/DaveWK/freebsd-src): official FreeBSD main plus the K1 board support, which covers:
  - clocks, pinctrl, GPIO, I2C and the P1 PMIC;
  - SDHCI;
  - the PCIe and NVMe fixes;
  - SMTE Ethernet, plus RTL8125 `rge` on the R2S;
  - SPI;
  - CPU frequency.

  The exact commit and tree are pinned in `config/freebsd.env`. The RTL8125 microcode is built into the driver, and neither board needs other firmware files.
- The userland is built for the SpacemiT X60 (`rv64gcv_zba_zbb_zbs`, `-mtune=spacemit-x60`; see `config/k1-world-make.conf`). The kernels use the ISA set in their configurations.
- Board configuration in `boards/<board>/`:
  - `loader.conf` loads the board DTB and sets the measured SMTE and NVMe tunables;
  - `rc.conf`, `fstab`, `sysctl.conf`.
- Runtime helpers from `runtime/<board>/`:
  - the fixed CPU operating point (`r2s_cpu`, `rv2_cpu`);
  - SMTE MAC addresses on the R2S;
  - devd rules;
  - `rv2-status`.
- The boot chain itself, under `/usr/local/share/k1-boot-chain/`. On the R2S, `r2s-boot-chain` installs it into the eMMC boot partitions.
- `/etc/freebsd-img-maker` records the source commits and the hashes of the kernel, loader, DTB and boot chain.

## Layout and installing

### RV2 (microSD)

| Offset | Content |
|---|---|
| 0 | SpacemiT BootROM descriptor (80 bytes, in the protective MBR's boot-code area) |
| 128 KiB, 512 KiB | bt0, two copies |
| 4 MiB, GPT 1 `boot1` | OpenSBI + EDK2 FIT (bt0 finds it by name) |
| 8 MiB, GPT 2 `rv2efi` | FAT16 ESP with `EFI/BOOT/BOOTRISCV64.EFI`, mounted at `/boot/efi` |
| 72 MiB, GPT 3 `rv2rootfs` | UFS2 root |

To install, write the image to a card and boot the board from it:

    dd if=out/rv2/freebsd-rv2.img of=/dev/sdX bs=4M conv=fsync

EDK2 in this image keeps UEFI variables in RAM and never writes the SPI NOR, so settings such as the boot order are not kept across power cycles.

To keep variables in the NOR instead, build your own image with `make rv2 UEFI_VARS=nor`. The build prints a warning because EDK2 then erases and formats NOR 0x2A0000–0x360000 on first boot whenever that range holds no variable store. That destroys any firmware there, such as the vendor's, so back up the NOR first.

### R2S (eMMC)

| Where | Content |
|---|---|
| eMMC boot0 | `boot0.bin`: BootROM descriptor and bt0 |
| eMMC boot1 | `next.img`: OpenSBI + EDK2 FIT |
| user area, GPT 1 `efiboot` | FAT16 ESP |
| user area, GPT 2 `r2srootfs` | UFS2 root |

Install from a workstation with `fastboot`. bt0 serves fastboot when it is started from the R2S's USB download mode:

1. With the board powered off, hold down the download button.
2. Connect the bottom USB-A port to the workstation with a USB-A to USB-A cable, then power the board on. The BootROM appears as USB device `361c:1001`.
3. Run:

       fastboot stage bt0.bin
       fastboot continue
       # bt0 trains DRAM and re-appears as a fastboot device (18d1:4ee0)
       fastboot flash emmc freebsd-r2s.img
       fastboot flash boot1 next.img
       fastboot flash boot0 boot0.bin
       fastboot continue

The flasher writes the eMMC with DMA on its 8-bit bus at about 30 MB/s, and TRIMs empty regions instead of writing zeros; the USB download runs at about 23 MB/s. After the final `continue`, the board boots the new system, which expands its root filesystem and generates SSH host keys on first boot.

On a board already running this image, `r2s-boot-chain install --yes` rewrites boot0 and boot1 from the copy in the image. It backs up both partitions first and reads the result back. `r2s-boot-chain status` compares without writing.

## Releases

Pushing a `v*` tag builds both images on a self-hosted Fedora 44 runner (labels `self-hosted, linux, x64, fedora44`). The images are attached to that tag's GitHub release as `.img.xz`, together with the boot-chain files and `SHA256SUMS`.

## Licence

BSD-2-Clause (`LICENSE`). `NOTICE` lists files taken from other projects and the licences of what the images contain.
