#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""SpacemiT K1 BootROM boot descriptors for oreboot's bt0.

The BootROM reads an 80-byte descriptor at byte 0 of the boot medium. It names
the copies of the first-stage loader (here oreboot's bt0) and their size limit.

On an SD card the descriptor fits in the protective MBR's boot-code area, so
the GPT is not touched, and both bt0 copies go into the gap between the GPT
entries and the first partition. On eMMC it starts the boot0 hardware
partition, with one bt0 copy right after it.

  k1-bootinfo.py descriptor sd|emmc OUT.bin   write a descriptor alone
  k1-bootinfo.py sd-install IMAGE.img BT0     SD descriptor + both bt0 copies
  k1-bootinfo.py sd-check IMAGE.img [BT0]     verify an SD image (read-only)
  k1-bootinfo.py emmc-boot0 BT0 OUT.bin       eMMC boot0 contents
"""
import struct
import sys
import zlib

SECTOR = 512
MAGIC = 0xB00714F0
VERSION = 0x00010001
DESCRIPTOR_SIZE = 80
# The descriptors SpacemiT's tools write: medium name, page size, block size
# and capacity hints, then the bt0 copies (0 = none) and their size limit.
MEDIA = {
    'sd': dict(name=b'SDC', page=0x200, block=0x10000, total=0x10000000,
               copies=(0x20000, 0x80000), limit=0x36000),
    'emmc': dict(name=b'eMMC', page=0x200, block=0x10000, total=0x10000000,
                 copies=(0x200, 0), limit=0x32100),
}
SD = MEDIA['sd']
BT0_COPY = SD['copies']  # 128 KiB and 512 KiB
BT0_LIMIT = SD['limit']


def descriptor(medium='sd') -> bytes:
    m = MEDIA[medium]
    d = bytearray(DESCRIPTOR_SIZE)
    struct.pack_into('<II4s', d, 0, MAGIC, VERSION, m['name'])
    struct.pack_into('<III', d, 16, m['page'], m['block'], m['total'])
    struct.pack_into('<III', d, 32, m['copies'][0], m['copies'][1], m['limit'])
    struct.pack_into('<I', d, 64, zlib.crc32(bytes(d[:64])))
    return bytes(d)


def emmc_boot0(bt0_path, out):
    m = MEDIA['emmc']
    bt0 = open(bt0_path, 'rb').read()
    if not bt0 or len(bt0) > m['limit']:
        fail(f'{bt0_path} is {len(bt0)} bytes; the limit is {m["limit"]:#x}')
    copy = m['copies'][0]
    image = descriptor('emmc') + bytes(copy - DESCRIPTOR_SIZE) + bt0 + bytes(m['limit'] - len(bt0))
    # Whole sectors, so it can be written to the boot0 device as is.
    image += bytes(-len(image) % SECTOR)
    open(out, 'wb').write(image)


def fail(msg):
    raise SystemExit('k1-bootinfo: ' + msg)


def first_partition_byte(f) -> int:
    """Byte offset of the first GPT partition, after checking the PMBR and GPT."""
    f.seek(510)
    if f.read(2) != b'\x55\xaa':
        fail('no MBR signature')
    f.seek(SECTOR)
    hdr = f.read(92)
    if hdr[:8] != b'EFI PART':
        fail('no GPT header at LBA 1')
    entries_lba, count, size = struct.unpack_from('<QII', hdr, 72)
    f.seek(entries_lba * SECTOR)
    table = f.read(count * size)
    starts = [struct.unpack_from('<Q', table, i * size + 32)[0]
              for i in range(count) if table[i * size:i * size + 16] != bytes(16)]
    if not starts:
        fail('GPT has no partitions')
    end_of_table = (entries_lba * SECTOR + count * size)
    first = min(starts) * SECTOR
    if BT0_COPY[0] < end_of_table:
        fail('the GPT entries overlap the first bt0 copy')
    if BT0_COPY[1] + BT0_LIMIT > first:
        fail(f'the first partition at {first:#x} overlaps the second bt0 copy')
    return first


def install(image, bt0_path):
    bt0 = open(bt0_path, 'rb').read()
    if not bt0 or len(bt0) > BT0_LIMIT:
        fail(f'{bt0_path} is {len(bt0)} bytes; the limit is {BT0_LIMIT:#x}')
    if BT0_COPY[0] + len(bt0) > BT0_COPY[1]:
        fail('bt0 would overlap its second copy')
    padded = bt0 + bytes(BT0_LIMIT - len(bt0))
    with open(image, 'r+b') as f:
        first_partition_byte(f)
        f.seek(0)
        if f.read(DESCRIPTOR_SIZE) != bytes(DESCRIPTOR_SIZE):
            fail('the MBR boot-code area is not empty')
        for off in BT0_COPY:
            f.seek(off)
            if f.read(BT0_LIMIT) != bytes(BT0_LIMIT):
                fail(f'the bt0 slot at {off:#x} is not empty')
        f.seek(0)
        f.write(descriptor())
        for off in BT0_COPY:
            f.seek(off)
            f.write(padded)
    check(image, bt0_path)


def check(image, bt0_path=None):
    with open(image, 'rb') as f:
        first_partition_byte(f)
        f.seek(0)
        if f.read(DESCRIPTOR_SIZE) != descriptor():
            fail('the K1 SD descriptor is missing or differs')
        if bt0_path:
            bt0 = open(bt0_path, 'rb').read()
            for off in BT0_COPY:
                f.seek(off)
                if f.read(BT0_LIMIT) != bt0 + bytes(BT0_LIMIT - len(bt0)):
                    fail(f'bt0 copy at {off:#x} differs')
    print(f'{image}: K1 SD descriptor and bt0 copies at '
          + ', '.join(f'{o:#x}' for o in BT0_COPY) + ' OK')


def main(argv):
    if len(argv) == 4 and argv[1] == 'descriptor' and argv[2] in MEDIA:
        open(argv[3], 'wb').write(descriptor(argv[2]))
    elif len(argv) == 4 and argv[1] == 'sd-install':
        install(argv[2], argv[3])
    elif len(argv) in (3, 4) and argv[1] == 'sd-check':
        check(argv[2], argv[3] if len(argv) == 4 else None)
    elif len(argv) == 4 and argv[1] == 'emmc-boot0':
        emmc_boot0(argv[2], argv[3])
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main(sys.argv)
