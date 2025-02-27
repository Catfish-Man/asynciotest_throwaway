/* SPDX-License-Identifier: MIT */
/*
 * gcc -Wall -O2 -D_GNU_SOURCE -o io_uring-cp io_uring-cp.c -luring
 */
#include <stdio.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include "liburing.h"
#include <sys/eventfd.h>
#include <fcntl.h>
#include <linux/fcntl.h>

#define FILE_COUNT 64

static int setup_context(unsigned entries, struct io_uring *ring)
{
	int ret;

	ret = io_uring_queue_init(entries, ring, 0);
	if (ret < 0) {
		fprintf(stderr, "queue_init: %s\n", strerror(-ret));
		return -1;
	}

	return 0;
}

struct io_uring *ring;

int main(int argc, char *argv[])
{
	unsigned long verificationSum = 0;
	ring = malloc(sizeof(struct io_uring));	
	if (setup_context(FILE_COUNT * 7, ring))
		return 1;

	int files[FILE_COUNT] = { 0 };
	io_uring_register_files(ring, files, FILE_COUNT);

	void *slab = calloc(FILE_COUNT, 16 * 1024 * 1024);
	memset(slab, 2, sizeof(*slab));

	struct iovec *buffers = calloc(sizeof(struct iovec), FILE_COUNT);
	for (int i = 0; i < FILE_COUNT; i++) {
		buffers[i].iov_base = slab + (i * 16 * 1024 * 1024);
		buffers[i].iov_len = 16 * 1024 * 1024;
	}

	io_uring_register_buffers(ring, buffers, FILE_COUNT);
	const char **filenames = calloc(sizeof(const char *), FILE_COUNT);
	for (int i = 0; i < FILE_COUNT; i++) {
		char filenameBuf[PATH_MAX] = { 0 };
		sprintf(filenameBuf, "testdatafile%d.txt", i);
		filenames[i] = strdup(filenameBuf);
	}

	for (int i = 0; i < FILE_COUNT; i++) {
		struct io_uring_sqe *openSQE = io_uring_get_sqe(ring);
		io_uring_prep_openat_direct(openSQE, AT_FDCWD, filenames[i], O_CREAT, O_RDWR, i);
		openSQE->flags |= IOSQE_IO_LINK;

		struct io_uring_sqe *writeSQE = io_uring_get_sqe(ring);
		io_uring_prep_write_fixed(writeSQE, i, buffers[i].iov_base, 16 * 1024 * 1024, 0, i);
		writeSQE->flags |= IOSQE_FIXED_FILE;
		writeSQE->flags |= IOSQE_IO_LINK;


		struct io_uring_sqe *closeSQE = io_uring_get_sqe(ring);
		io_uring_prep_close_direct(closeSQE, i);
	}

	memset(slab, 0, sizeof(*slab));

	for (int i = 0; i < FILE_COUNT; i++) {
		struct io_uring_sqe *openSQE = io_uring_get_sqe(ring);
		io_uring_prep_openat_direct(openSQE, AT_FDCWD, filenames[i], O_CREAT, O_RDWR, i);
		openSQE->flags |= IOSQE_IO_LINK;

		struct io_uring_sqe *readSQE = io_uring_get_sqe(ring);
		io_uring_prep_read_fixed(readSQE, i, buffers[i].iov_base, 16 * 1024 * 1024, 0, i);
		readSQE->flags |= IOSQE_IO_LINK;
		readSQE->user_data = (uint64_t)buffers[i].iov_base;

		struct io_uring_sqe *closeSQE = io_uring_get_sqe(ring);
		io_uring_prep_close_direct(closeSQE, i);
		closeSQE->flags |= IOSQE_IO_LINK;

		struct io_uring_sqe *unlinkSQE = io_uring_get_sqe(ring);
		io_uring_prep_unlinkat(unlinkSQE, AT_FDCWD, filenames[i], 0);
	}

	int completedOperationCount = 0;
	bool doneWriting = false;
	uint64_t sum = 0;
	for (int i = 0; i < FILE_COUNT; i++) {
		completedOperationCount++;
		struct io_uring_cqe *cqe;
		int ret = io_uring_wait_cqe(ring, &cqe);
		io_uring_cqe_seen(ring, cqe);
		if (ret < 0) {
			printf("Failed with %s", strerror(ret));
		} else {
			if (cqe->user_data > 0) {
				completedOperationCount++;
				sum += *((int *)cqe->user_data);
			}
			if (!doneWriting && completedOperationCount == FILE_COUNT * 3) {
				doneWriting = true;
				completedOperationCount = 0;
			}
			if (doneWriting && completedOperationCount == FILE_COUNT * 4) {
				printf("Sum of all values is %lu, expected result is %lu", sum, verificationSum);
				_exit(sum == verificationSum ? 0 : 1);
			}
		}
	}
	
	return 0;
}