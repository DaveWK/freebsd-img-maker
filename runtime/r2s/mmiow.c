/* mmiow - write one 32-bit word to physical memory via /dev/mem */
#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>

int
main(int argc, char **argv)
{
	uint64_t pa, base, off;
	uint32_t val;
	int fd;
	volatile uint32_t *p;

	if (argc != 3) {
		fprintf(stderr, "usage: mmiow <phys-addr> <value>\n");
		return (1);
	}
	pa = strtoull(argv[1], NULL, 0);
	val = (uint32_t)strtoul(argv[2], NULL, 0);

	base = pa & ~(uint64_t)(getpagesize() - 1);
	off = pa - base;

	if ((fd = open("/dev/mem", O_RDWR)) < 0) {
		perror("open /dev/mem");
		return (1);
	}
	p = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE, MAP_SHARED, fd,
	    (off_t)base);
	if (p == MAP_FAILED) {
		perror("mmap");
		return (1);
	}
	p = (volatile uint32_t *)((volatile char *)p + off);
	printf("%#lx: %08x -> %08x\n", (unsigned long)pa, p[0], val);
	p[0] = val;
	printf("%#lx: readback %08x\n", (unsigned long)pa, p[0]);
	return (0);
}
