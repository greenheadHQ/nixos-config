#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
#include <sys/sysctl.h>
#include <sys/types.h>
#elif defined(__linux__)
#include <fcntl.h>
#include <sys/types.h>
#include <unistd.h>
#else
#error "claude-rc-pid-argv supports only Darwin and Linux"
#endif

#define MAX_ARGV_BYTES (16U * 1024U * 1024U)

static int parse_pid(const char *text, pid_t *pid_out) {
    char *end = NULL;
    long parsed;

    errno = 0;
    parsed = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed <= 0 ||
        parsed > INT_MAX) {
        return -1;
    }
    *pid_out = (pid_t)parsed;
    return 0;
}

#ifdef __APPLE__
static int emit_argv(pid_t pid) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    unsigned char *buffer;
    unsigned char *cursor;
    unsigned char *end;
    unsigned char *argv_start;
    size_t size = 0;
    int argc;
    int index;

    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 ||
        size < sizeof(argc) || size > MAX_ARGV_BYTES) {
        return -1;
    }
    buffer = malloc(size);
    if (buffer == NULL) {
        return -1;
    }
    if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0 ||
        size < sizeof(argc)) {
        free(buffer);
        return -1;
    }

    memcpy(&argc, buffer, sizeof(argc));
    if (argc <= 0) {
        free(buffer);
        return -1;
    }
    cursor = buffer + sizeof(argc);
    end = buffer + size;

    /* KERN_PROCARGS2 stores exec_path, NUL padding, then argc argv strings. */
    while (cursor < end && *cursor != '\0') {
        cursor++;
    }
    while (cursor < end && *cursor == '\0') {
        cursor++;
    }
    argv_start = cursor;
    for (index = 0; index < argc; index++) {
        unsigned char *terminator;
        if (cursor >= end) {
            free(buffer);
            return -1;
        }
        terminator = memchr(cursor, '\0', (size_t)(end - cursor));
        if (terminator == NULL) {
            free(buffer);
            return -1;
        }
        cursor = terminator + 1;
    }

    if (fwrite(argv_start, 1, (size_t)(cursor - argv_start), stdout) !=
        (size_t)(cursor - argv_start)) {
        free(buffer);
        return -1;
    }
    free(buffer);
    return 0;
}
#elif defined(__linux__)
static int emit_argv(pid_t pid) {
    char path[64];
    unsigned char *buffer = NULL;
    size_t capacity = 4096;
    size_t length = 0;
    int fd;

    if (snprintf(path, sizeof(path), "/proc/%ld/cmdline", (long)pid) <= 0) {
        return -1;
    }
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }
    buffer = malloc(capacity);
    if (buffer == NULL) {
        close(fd);
        return -1;
    }

    for (;;) {
        ssize_t count;
        if (length == capacity) {
            unsigned char *grown;
            if (capacity >= MAX_ARGV_BYTES) {
                free(buffer);
                close(fd);
                return -1;
            }
            capacity *= 2;
            if (capacity > MAX_ARGV_BYTES) {
                capacity = MAX_ARGV_BYTES;
            }
            grown = realloc(buffer, capacity);
            if (grown == NULL) {
                free(buffer);
                close(fd);
                return -1;
            }
            buffer = grown;
        }
        count = read(fd, buffer + length, capacity - length);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            free(buffer);
            close(fd);
            return -1;
        }
        if (count == 0) {
            break;
        }
        length += (size_t)count;
    }
    close(fd);
    if (length == 0 || buffer[length - 1] != '\0') {
        free(buffer);
        return -1;
    }
    if (fwrite(buffer, 1, length, stdout) != length) {
        free(buffer);
        return -1;
    }
    free(buffer);
    return 0;
}
#endif

int main(int argc, char **argv) {
    pid_t pid;

    if (argc != 2 || parse_pid(argv[1], &pid) != 0) {
        fprintf(stderr, "usage: claude-rc-pid-argv PID\n");
        return 2;
    }
    return emit_argv(pid) == 0 ? 0 : 1;
}
