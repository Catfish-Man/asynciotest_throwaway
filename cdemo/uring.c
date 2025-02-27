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

#define FILE_COUNT 4ul

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
	uint64_t verificationSum = 16ul * 1024ul * 1024ul * FILE_COUNT * 2ul;
	ring = malloc(sizeof(struct io_uring));	
	if (setup_context(FILE_COUNT * 7, ring))
		return 1;

	int files[FILE_COUNT] = { -1};
	int fileResult = io_uring_register_files(ring, files, FILE_COUNT);
	if (fileResult < 0) {
		printf("Failed to register files %s", strerror(-(fileResult)));
		return 1;
	}

	void *slab = calloc(FILE_COUNT, 16 * 1024 * 1024);
	memset(slab, 2, 16 * 1024 * 1024 * FILE_COUNT);

	struct iovec *buffers = calloc(sizeof(struct iovec), FILE_COUNT);
	for (int i = 0; i < FILE_COUNT; i++) {
		buffers[i].iov_base = slab + (i * 16 * 1024 * 1024);
		buffers[i].iov_len = 16 * 1024 * 1024;
	}

	int bufResult = io_uring_register_buffers(ring, buffers, FILE_COUNT);
	if (bufResult < 0) {
		printf("Failed to register files %s", strerror(-(fileResult)));
		return 1;
	}

	const char **filenames = calloc(sizeof(const char *), FILE_COUNT);
	for (int i = 0; i < FILE_COUNT; i++) {
		char filenameBuf[PATH_MAX] = { 0 };
		sprintf(filenameBuf, "testdatafile%d.txt", i);
		filenames[i] = strdup(filenameBuf);
	}

	for (int i = 0; i < FILE_COUNT; i++) {
		struct io_uring_sqe *openSQE = io_uring_get_sqe(ring);
		io_uring_prep_openat_direct(openSQE, AT_FDCWD, filenames[i], O_CREAT | O_RDWR, 0600, i);
		io_uring_sqe_set_flags(openSQE, IOSQE_IO_LINK | IOSQE_CQE_SKIP_SUCCESS);

		struct io_uring_sqe *writeSQE = io_uring_get_sqe(ring);
		io_uring_prep_write_fixed(writeSQE, i, buffers[i].iov_base, 16 * 1024 * 1024, 0, i);
		io_uring_sqe_set_flags(writeSQE, IOSQE_FIXED_FILE |  IOSQE_IO_LINK | IOSQE_CQE_SKIP_SUCCESS);

		struct io_uring_sqe *closeSQE = io_uring_get_sqe(ring);
		io_uring_prep_close_direct(closeSQE, i);
		io_uring_sqe_set_data64(closeSQE, i + 1);
	}
	io_uring_submit(ring);

	int completedWriteChains = 0;
	while (true) {
		struct io_uring_cqe *cqe;
		int ret = io_uring_wait_cqe(ring, &cqe);
		io_uring_cqe_seen(ring, cqe);
		printf("ret %d, res %d and data %lld\n", ret, cqe->res, io_uring_cqe_get_data64(cqe));
		if (ret < 0 || cqe->res < 0) {
			printf("Failed with %s and %s, user_data: %lld\n", strerror(ret), strerror(-(cqe->res)), io_uring_cqe_get_data64(cqe));
		}
		if (io_uring_cqe_get_data64(cqe) > 0) {
			printf("completed write chain for %lld\n", io_uring_cqe_get_data64(cqe));
			completedWriteChains += 1;
			if (completedWriteChains == FILE_COUNT) {
				break;
			}
		}
	}

	memset(slab, 0, sizeof(*slab));

	for (int i = 0; i < FILE_COUNT; i++) {
		struct io_uring_sqe *openSQE = io_uring_get_sqe(ring);
		io_uring_prep_openat_direct(openSQE, AT_FDCWD, filenames[i], O_RDONLY, 0, i);
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

	io_uring_submit(ring);

	int completedOperationCount = 0;
	uint64_t sum = 0;
	for (int i = 0; i < FILE_COUNT * 4; i++) {
		printf("Saw a result for read chains");
		completedOperationCount++;
		struct io_uring_cqe *cqe;
		int ret = io_uring_wait_cqe(ring, &cqe);
		io_uring_cqe_seen(ring, cqe);
		if (ret < 0 || cqe->res < 0) {
			printf("Failed with %s and %s\n", strerror(ret), strerror(-(cqe->res)));
		} else {
			if (cqe->user_data > 0) {
				completedOperationCount++;
				uint8_t *dataPtr = (uint8_t *)io_uring_cqe_get_data(cqe);
				for (int dataIdx = 0; dataIdx < cqe->res; dataIdx++) {
					sum += dataPtr[dataIdx];
				}
				printf("Running total is %lu", sum);
			}
		}
	}
	printf("Sum of all values is %lu, expected result is %lu", sum, verificationSum);
	return sum == verificationSum ? 0 : 1;
}