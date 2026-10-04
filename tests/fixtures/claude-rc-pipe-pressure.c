#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Model a 512-byte Darwin pipe only for the real maint metadata heredoc.
 * Never exhaust the host's pipe memory. The Python supervisor owns a fresh
 * process group and kills every stalled fixture process on its deadline. */
static ssize_t constrained_write(int fd, const void *buffer, size_t length) {
    const char marker[] = "path-missing\tstopped\tfalse\n";
    struct stat metadata;
    if (strcmp(getprogname(), "bash") == 0 && length > 512
        && length >= sizeof(marker) - 1
        && memcmp(buffer, marker, sizeof(marker) - 1) == 0
        && fstat(fd, &metadata) == 0 && S_ISFIFO(metadata.st_mode)) {
        int flags = fcntl(fd, F_GETFL);
        const char *evidence = getenv("CLAUDE_RC_PIPE_EVIDENCE");
        if (flags < 0) {
            return -1;
        }
        if (evidence != NULL) {
            int log_fd = open(evidence, O_WRONLY | O_APPEND | O_CREAT, 0600);
            if (log_fd >= 0) {
                const char *state = (flags & O_NONBLOCK)
                    ? "nonblocking-eagain\n" : "blocking-stall\n";
                (void)write(log_fd, state, strlen(state));
                close(log_fd);
            }
        }
        if (!(flags & O_NONBLOCK)) {
            for (;;) {
                pause();
            }
        }
        errno = EAGAIN;
        return -1;
    }
    /* cat's write after the patched Bash falls back to a regular file must
     * pass through, even when it contains the same metadata text. */
    return write(fd, buffer, length);
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} interpose_write __attribute__((section("__DATA,__interpose"))) = {
    (const void *)constrained_write,
    (const void *)write
};
