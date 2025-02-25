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

#define FILE_COUNT 64

struct io_data {
	int read;
	off_t first_offset, offset;
	size_t first_len;
	struct iovec iov;
};

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

static void queue_prepped(struct io_uring *ring, struct io_data *data)
{
	struct io_uring_sqe *sqe;

	sqe = io_uring_get_sqe(ring);
	assert(sqe);

	if (data->read)
		io_uring_prep_readv(sqe, infd, &data->iov, 1, data->offset);
	else
		io_uring_prep_writev(sqe, outfd, &data->iov, 1, data->offset);

	io_uring_sqe_set_data(sqe, data);
}

static int queue_read(struct io_uring *ring, off_t size, off_t offset)
{
	struct io_uring_sqe *sqe;
	struct io_data *data;

	data = malloc(size + sizeof(*data));
	if (!data)
		return 1;

	sqe = io_uring_get_sqe(ring);
	if (!sqe) {
		free(data);
		return 1;
	}

	data->read = 1;
	data->offset = data->first_offset = offset;

	data->iov.iov_base = data + 1;
	data->iov.iov_len = size;
	data->first_len = size;

	io_uring_prep_readv(sqe, infd, &data->iov, 1, offset);
	io_uring_sqe_set_data(sqe, data);
	return 0;
}

static void queue_openat(const char *path,
	int dfd,
	int flags,
	mode_t mode,
	unsigned file_index
) {
	struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
	io_uring_prep_openat_direct(sqe, dfd, path, flags, mode, file_index);
	sqe->flags |= IOSQE_IO_LINK_BIT;
}

static void queue_write(struct io_uring *ring, struct io_data *data)
{
	data->read = 0;
	data->offset = data->first_offset;

	data->iov.iov_base = data + 1;
	data->iov.iov_len = data->first_len;

	queue_prepped(ring, data);
	io_uring_submit(ring);
}

static int copy_file(struct io_uring *ring, off_t insize)
{
	unsigned long reads, writes;
	struct io_uring_cqe *cqe;
	off_t write_left, offset;
	int ret;

	write_left = insize;
	writes = reads = offset = 0;

	while (insize || write_left) {
		unsigned long had_reads;
		int got_comp;
	
		/*
		 * Queue up as many reads as we can
		 */
		had_reads = reads;
		while (insize) {
			off_t this_size = insize;

			if (reads + writes >= QD)
				break;
			if (this_size > BS)
				this_size = BS;
			else if (!this_size)
				break;

			if (queue_read(ring, this_size, offset))
				break;

			insize -= this_size;
			offset += this_size;
			reads++;
		}

		if (had_reads != reads) {
			ret = io_uring_submit(ring);
			if (ret < 0) {
				fprintf(stderr, "io_uring_submit: %s\n", strerror(-ret));
				break;
			}
		}

		/*
		 * Queue is full at this point. Find at least one completion.
		 */
		got_comp = 0;
		while (write_left) {
			struct io_data *data;

			if (!got_comp) {
				ret = io_uring_wait_cqe(ring, &cqe);
				got_comp = 1;
			} else {
				ret = io_uring_peek_cqe(ring, &cqe);
				if (ret == -EAGAIN) {
					cqe = NULL;
					ret = 0;
				}
			}
			if (ret < 0) {
				fprintf(stderr, "io_uring_peek_cqe: %s\n",
							strerror(-ret));
				return 1;
			}
			if (!cqe)
				break;

			data = io_uring_cqe_get_data(cqe);
			if (cqe->res < 0) {
				if (cqe->res == -EAGAIN) {
					queue_prepped(ring, data);
					io_uring_submit(ring);
					io_uring_cqe_seen(ring, cqe);
					continue;
				}
				fprintf(stderr, "cqe failed: %s\n",
						strerror(-cqe->res));
				return 1;
			} else if ((size_t)cqe->res != data->iov.iov_len) {
				/* Short read/write, adjust and requeue */
				data->iov.iov_base += cqe->res;
				data->iov.iov_len -= cqe->res;
				data->offset += cqe->res;
				queue_prepped(ring, data);
				io_uring_submit(ring);
				io_uring_cqe_seen(ring, cqe);
				continue;
			}

			/*
			 * All done. if write, nothing else to do. if read,
			 * queue up corresponding write.
			 */
			if (data->read) {
				queue_write(ring, data);
				write_left -= data->first_len;
				reads--;
				writes++;
			} else {
				free(data);
				writes--;
			}
			io_uring_cqe_seen(ring, cqe);
		}
	}

	/* wait out pending writes */
	while (writes) {
		struct io_data *data;

		ret = io_uring_wait_cqe(ring, &cqe);
		if (ret) {
			fprintf(stderr, "wait_cqe=%d\n", ret);
			return 1;
		}
		if (cqe->res < 0) {
			fprintf(stderr, "write res=%d\n", cqe->res);
			return 1;
		}
		data = io_uring_cqe_get_data(cqe);
		free(data);
		writes--;
		io_uring_cqe_seen(ring, cqe);
	}

	return 0;
}

struct io_uring *ring;

int main(int argc, char *argv[])
{
	atomic_ulong sum = 0;
	unsigned long verificationSum = 0;
	ring = malloc(sizeof(struct io_uring));	
	if (setup_context(FILE_COUNT * 7, ring))
		return 1;

	int files[FILE_COUNT] = { 0 };
	io_uring_register_files(&ring, files, FILE_COUNT);

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
		sprintf(filenameBuf, "testdatafile%ld.txt", i);
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
		readSQE->user_data = buffers[i].iov_base;

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
		struct io_uring_cqe cqe;
		int ret = io_uring_wait_cqe(ring, &cqe);
		if (ret < 0) {
			printf("Failed with %s", syserror(ret));
		} else {
			if (cqe.user_data > 0) {
				completedOperationCount++;
				sum += *((int *)cqe.user_data);
			}
			if (!doneWriting && completedOperationCount == FILE_COUNT * 3) {
				doneWriting = true;
				completedOperationCount = 0;
			}
			if (doneWriting && completedOperationCount == FILE_COUNT * 4) {
				print("Sum of all values is %lu, expected result is %lu", sum, verificationSum);
				_exit(sum == verificationSum ? 0 : 1);
			}
		}
	}
	
	return 0;
}