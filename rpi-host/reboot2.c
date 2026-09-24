/*
 * rpi-reboot2 ARG: reboot with a restart argument (LINUX_REBOOT_CMD_RESTART2).
 * On Raspberry Pi the watchdog driver takes a leading number as the firmware
 * boot partition for the next boot only. Busybox reboot has no way to pass
 * one; systemd's `reboot --reboot-argument` is not available here.
 */
#include <linux/reboot.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s ARG\n", argv[0]);
		return 2;
	}
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, argv[1]);
	perror("reboot");
	return 1;
}
