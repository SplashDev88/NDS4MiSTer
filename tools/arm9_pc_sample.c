// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only native collector for NDS_ARM9_PC_PROFILE. Emit data after sampling
// so formatting/allocation do not run alongside measured gameplay.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

struct sample { uint64_t ns; uint32_t pc, meta; };
static uint64_t now(clockid_t clock) {
    struct timespec t;
    if (clock_gettime(clock, &t)) { perror("clock_gettime"); exit(1); }
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + t.tv_nsec;
}
static int healthy(volatile const uint32_t *p, uint32_t session) {
    return p[0] == UINT32_C(0x31443348) && p[2] == session && !p[8] && !p[9];
}
static int observe(volatile const uint32_t *p, uint32_t *pc, uint32_t *meta) {
    uint32_t a = p[24], b = p[25];
    __sync_synchronize();
    uint32_t c = p[24], d = p[25];
    if (a != c || b != d) return 0;
    *pc = a; *meta = b; return 1;
}

#ifdef PC_SAMPLE_TEST
#include <assert.h>
int main(void) {
    uint32_t p[32] = {0}, pc = 0, meta = 0;
    p[0] = UINT32_C(0x31443348); p[2] = 7;
    assert(healthy(p, 7)); assert(!healthy(p, 8));
    p[8] = 1; assert(!healthy(p, 7)); p[8] = 0;
    p[24] = UINT32_C(0x02001008); p[25] = UINT32_C(0xb40001ff);
    assert(observe(p, &pc, &meta) && pc == p[24] && meta == p[25]);
    assert((uint8_t)(UINT32_C(0xb4000200) - meta - 1) == 0);
    assert(now(CLOCK_MONOTONIC) > 0);
    puts("PASS: native collector read-only sample, health/session and sequence wrap");
    return 0;
}
#else
int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "Usage: %s milliseconds poll_microseconds\n", argv[0]); return 2; }
    char *end;
    long ms = strtol(argv[1], &end, 10);
    if (*end || ms < 1000 || ms > 60000) return 2;
    long us = strtol(argv[2], &end, 10);
    if (*end || us < 100 || us > 10000) return 2;
    struct sample *samples = calloc(65536, sizeof(*samples));
    if (!samples) { perror("calloc"); return 1; }
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); free(samples); return 1; }
    volatile const uint32_t *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0x3fc00000);
    close(fd);
    if (p == MAP_FAILED) { perror("mmap"); free(samples); return 1; }
    uint32_t session = p[2], previous_pc = 0, previous_meta = 0;
    uint64_t start = now(CLOCK_MONOTONIC), cpu = now(CLOCK_PROCESS_CPUTIME_ID);
    uint64_t check = start, elapsed = 0, lost = 0;
    unsigned count = 0;
    int failed = 0;
    struct timespec pause = {0, us * 1000};
    while ((elapsed = now(CLOCK_MONOTONIC) - start) < (uint64_t)ms * 1000000) {
        if (start + elapsed >= check) {
            if (!healthy(p, session)) { failed = 1; break; }
            check = start + elapsed + UINT64_C(10000000);
        }
        uint32_t pc, meta;
        if (observe(p, &pc, &meta)) {
            if ((meta >> 28) != 0xb) {
                if (elapsed > UINT64_C(1000000000)) { failed = 2; break; }
            } else if (!count || pc != previous_pc || meta != previous_meta) {
                if (count == 65536) { failed = 3; break; }
                if (count) lost += (uint8_t)(meta - previous_meta - 1);
                samples[count++] = (struct sample){elapsed, pc, meta};
                previous_pc = pc; previous_meta = meta;
            }
        }
        struct timespec remaining = pause;
        while (nanosleep(&remaining, &remaining) && errno == EINTR) {}
    }
    if (!healthy(p, session)) failed = 1;
    cpu = now(CLOCK_PROCESS_CPUTIME_ID) - cpu;
    munmap((void *)p, 4096);
    if (failed || !count) {
        fprintf(stderr, "Native PC capture rejected: %d (1=health/session, 2=tag, 3=capacity); samples=%u\n", failed, count);
        free(samples); return 1;
    }
    printf("NDS-PC-v1,%" PRIu32 ",%" PRIu64 ",%" PRIu64 ",%u,%" PRIu64 "\n", session, elapsed, cpu, count, lost);
    for (unsigned i = 0; i < count; ++i)
        printf("%" PRIu64 ",%" PRIu32 ",%" PRIu32 "\n", samples[i].ns, samples[i].pc, samples[i].meta);
    free(samples);
    return ferror(stdout) ? 1 : 0;
}
#endif
