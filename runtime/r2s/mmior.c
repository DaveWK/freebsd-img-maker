/* mmior - dump 32-bit words from physical memory via /dev/mem */
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
	int fd, n, i;
	volatile uint32_t *p;
	size_t len;

	if (argc < 2) {
		fprintf(stderr, "usage: mmior <phys-addr> [nwords]\n");
		return (1);
	}
	pa = strtoull(argv[1], NULL, 0);
	n = (argc > 2) ? atoi(argv[2]) : 16;

	base = pa & ~(uint64_t)(getpagesize() - 1);
	off = pa - base;
	len = off + (size_t)n * 4;
	len = (len + getpagesize() - 1) & ~(size_t)(getpagesize() - 1);

	if ((fd = open("/dev/mem", O_RDONLY)) < 0) {
		perror("open /dev/mem");
		return (1);
	}
	p = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, (off_t)base);
	if (p == MAP_FAILED) {
		perror("mmap");
		return (1);
	}
	p = (volatile uint32_t *)((volatile char *)p + off);
	for (i = 0; i < n; i++) {
		if (i % 4 == 0)
			printf("\n%#018lx:", (unsigned long)(pa + i * 4));
		printf(" %08x", p[i]);
	}
	printf("\n");
	return (0);
}
