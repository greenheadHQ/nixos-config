#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#error "claude-rc-launch-group requires O_CLOEXEC"
#endif

#ifndef O_NOFOLLOW
#error "claude-rc-launch-group requires O_NOFOLLOW"
#endif

enum launch_group_status {
    LAUNCH_GROUP_STATUS_OK = 0,
    LAUNCH_GROUP_STATUS_USAGE = 64,
    LAUNCH_GROUP_STATUS_SETUP_FAILED = 70,
    LAUNCH_GROUP_STATUS_FORK_FAILED = 71,
    LAUNCH_GROUP_STATUS_EXEC_GATE_CLOSED = 72,
    LAUNCH_GROUP_STATUS_PUBLICATION_FAILED = 73,
    LAUNCH_GROUP_STATUS_PRE_HANDOFF_ABORTED = 74,
    LAUNCH_GROUP_STATUS_EXEC_NOT_EXECUTABLE = 126,
    LAUNCH_GROUP_STATUS_EXEC_NOT_FOUND = 127,
    LAUNCH_GROUP_STATUS_CLEANUP_FALLBACK = 143,
};

static volatile sig_atomic_t handoff_requested = 0;
static volatile sig_atomic_t cleanup_requested = 0;

static void request_handoff(int signal_number) {
    (void)signal_number;
    handoff_requested = 1;
}

static void request_cleanup(int signal_number) {
    (void)signal_number;
    cleanup_requested = 1;
}

static int install_handler(int signal_number, void (*handler)(int)) {
    struct sigaction action;

    memset(&action, 0, sizeof(action));
    action.sa_handler = handler;
    if (sigemptyset(&action.sa_mask) != 0) {
        return -1;
    }
    return sigaction(signal_number, &action, NULL);
}

static int write_all(int fd, const char *buffer, size_t length) {
    size_t written = 0;

    while (written < length) {
        ssize_t result = write(fd, buffer + written, length - written);
        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (result == 0) {
            errno = EIO;
            return -1;
        }
        written += (size_t)result;
    }
    return 0;
}

static int publish_child_pid(const char *path, pid_t child_pid) {
    char buffer[64];
    struct stat metadata;
    int fd;
    int length;

    fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        return -1;
    }
    if (fstat(fd, &metadata) != 0 || !S_ISREG(metadata.st_mode)
        || metadata.st_uid != geteuid() || metadata.st_nlink != 1
        || (metadata.st_mode & 077) != 0 || ftruncate(fd, 0) != 0) {
        int saved_errno = errno == 0 ? EINVAL : errno;
        close(fd);
        errno = saved_errno;
        return -1;
    }

    length = snprintf(buffer, sizeof(buffer), "%ld\n", (long)child_pid);
    if (length <= 0 || (size_t)length >= sizeof(buffer)
        || write_all(fd, buffer, (size_t)length) != 0) {
        int saved_errno = errno == 0 ? EIO : errno;
        close(fd);
        errno = saved_errno;
        return -1;
    }
    if (close(fd) != 0) {
        return -1;
    }
    return 0;
}

static void kill_and_reap_child(pid_t child_pid) {
    int status;

    (void)kill(child_pid, SIGKILL);
    while (waitpid(child_pid, &status, 0) < 0 && errno == EINTR) {
    }
}

static void kill_process_group(void) {
    (void)kill(0, SIGKILL);
    _exit(LAUNCH_GROUP_STATUS_CLEANUP_FALLBACK);
}

int main(int argc, char **argv) {
    const struct timespec poll_interval = { .tv_sec = 0, .tv_nsec = 10000000L };
    pid_t guardian_pid;
    pid_t child_pid;
    int gate[2];
    char token = '1';

    if (argc < 3) {
        fprintf(stderr, "claude-rc-launch-group: expected PID_FILE COMMAND [ARG...]\n");
        return LAUNCH_GROUP_STATUS_USAGE;
    }

    guardian_pid = getppid();
    if (guardian_pid <= 1) {
        fprintf(stderr, "claude-rc-launch-group: invalid guardian\n");
        return LAUNCH_GROUP_STATUS_SETUP_FAILED;
    }
    if (setpgid(0, 0) != 0 || pipe(gate) != 0) {
        fprintf(stderr, "claude-rc-launch-group: setup failed: %s\n", strerror(errno));
        return LAUNCH_GROUP_STATUS_SETUP_FAILED;
    }

    child_pid = fork();
    if (child_pid < 0) {
        fprintf(stderr, "claude-rc-launch-group: fork failed: %s\n", strerror(errno));
        close(gate[0]);
        close(gate[1]);
        return LAUNCH_GROUP_STATUS_FORK_FAILED;
    }
    if (child_pid == 0) {
        ssize_t result;

        close(gate[1]);
        do {
            result = read(gate[0], &token, 1);
        } while (result < 0 && errno == EINTR);
        close(gate[0]);
        if (result != 1) {
            _exit(LAUNCH_GROUP_STATUS_EXEC_GATE_CLOSED);
        }
        execvp(argv[2], &argv[2]);
        _exit(errno == ENOENT
            ? LAUNCH_GROUP_STATUS_EXEC_NOT_FOUND
            : LAUNCH_GROUP_STATUS_EXEC_NOT_EXECUTABLE);
    }

    close(gate[0]);
    if (install_handler(SIGUSR1, request_handoff) != 0
        || install_handler(SIGHUP, request_cleanup) != 0
        || install_handler(SIGTERM, request_cleanup) != 0
        || install_handler(SIGINT, request_cleanup) != 0
        || publish_child_pid(argv[1], child_pid) != 0) {
        fprintf(stderr, "claude-rc-launch-group: publication failed: %s\n", strerror(errno));
        close(gate[1]);
        kill_and_reap_child(child_pid);
        return LAUNCH_GROUP_STATUS_PUBLICATION_FAILED;
    }
    if (cleanup_requested || handoff_requested || getppid() != guardian_pid
        || write_all(gate[1], &token, 1) != 0) {
        close(gate[1]);
        kill_and_reap_child(child_pid);
        return LAUNCH_GROUP_STATUS_PRE_HANDOFF_ABORTED;
    }
    close(gate[1]);

    while (true) {
        if (cleanup_requested || getppid() != guardian_pid) {
            kill_process_group();
        }
        if (handoff_requested) {
            return LAUNCH_GROUP_STATUS_OK;
        }
        if (nanosleep(&poll_interval, NULL) != 0 && errno != EINTR) {
            kill_process_group();
        }
    }
}
