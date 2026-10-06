/* pmicw <reg> [value]  — read, or read-modify-OR-write, a P1 PMIC register
 * via the raw I2CRDWR ioctl. With no value, reads only. */
#include <sys/types.h>
#include <sys/ioctl.h>
#include <dev/iicbus/iic.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#define SLAVE (0x41 << 1)
static int rd8(int fd, uint8_t reg, uint8_t *out) {
	uint8_t r = reg;
	struct iic_msg m[2] = {
		{ .slave = SLAVE, .flags = IIC_M_WR, .len = 1, .buf = &r },
		{ .slave = SLAVE, .flags = IIC_M_RD, .len = 1, .buf = out },
	};
	struct iic_rdwr_data d = { .msgs = m, .nmsgs = 2 };
	return ioctl(fd, I2CRDWR, &d);
}
static int wr8(int fd, uint8_t reg, uint8_t val) {
	uint8_t b[2] = { reg, val };
	struct iic_msg m[1] = {{ .slave = SLAVE, .flags = IIC_M_WR, .len = 2, .buf = b }};
	struct iic_rdwr_data d = { .msgs = m, .nmsgs = 1 };
	return ioctl(fd, I2CRDWR, &d);
}
int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr,
	    "usage: pmicw <reg>            read\n"
	    "       pmicw <reg> <or-value> read-modify-OR-write\n"
	    "       pmicw <reg> =<value>   write exactly\n"); return 2; }
	uint8_t reg = (uint8_t)strtoul(argv[1], NULL, 0), val = 0;
	int fd = open("/dev/iic1", O_RDWR);
	if (fd < 0) { perror("open /dev/iic1"); return 1; }
	if (rd8(fd, reg, &val) != 0) { perror("read"); return 1; }
	printf("reg 0x%02x = 0x%02x\n", reg, val);
	if (argc >= 3) {
		int exact = (argv[2][0] == '=');
		uint8_t arg = (uint8_t)strtoul(argv[2] + (exact ? 1 : 0), NULL, 0);
		uint8_t nv = exact ? arg : (uint8_t)(val | arg);
		printf("writing 0x%02x (%s 0x%02x)\n", nv, exact ? "=" : "|=", arg);
		if (wr8(fd, reg, nv) != 0) { perror("write"); return 1; }
		if (rd8(fd, reg, &val) == 0) printf("readback = 0x%02x\n", val);
	}
	return 0;
}
