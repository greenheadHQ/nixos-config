#include <CoreFoundation/CoreFoundation.h>

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_INPUT_BYTES (64U * 1024U)

static void secure_zero(void *buffer, size_t length) {
    volatile unsigned char *cursor = buffer;

    while (length > 0U) {
        *cursor++ = 0U;
        length--;
    }
}

static int read_stdin(unsigned char **buffer_out, size_t *length_out) {
    unsigned char *buffer;
    size_t length = 0;

    buffer = malloc(MAX_INPUT_BYTES + 1U);
    if (buffer == NULL) {
        return -1;
    }

    for (;;) {
        ssize_t count = read(STDIN_FILENO, buffer + length,
                             (MAX_INPUT_BYTES + 1U) - length);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            secure_zero(buffer, length);
            free(buffer);
            return -1;
        }
        if (count == 0) {
            break;
        }
        length += (size_t)count;
        if (length > MAX_INPUT_BYTES) {
            secure_zero(buffer, length);
            free(buffer);
            return -1;
        }
    }

    if (length == 0) {
        free(buffer);
        return -1;
    }
    *buffer_out = buffer;
    *length_out = length;
    return 0;
}

int main(int argc, char **argv) {
    unsigned char *input = NULL;
    size_t input_length = 0;
    CFStringRef target = NULL;
    CFStringRef key = NULL;
    CFStringRef value = NULL;
    bool synchronized = false;
    int status = 1;

    if (argc != 3 || argv[1][0] != '/' || argv[2][0] == '\0') {
        fprintf(stderr,
                "usage: shottr-cfpreferences-writer ABSOLUTE_PREFERENCES_BASENAME KEY\n");
        return 2;
    }
    if (read_stdin(&input, &input_length) != 0) {
        fprintf(stderr, "invalid preference value input\n");
        return 1;
    }

    target = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault,
                                                         argv[1]);
    key = CFStringCreateWithCString(kCFAllocatorDefault, argv[2],
                                    kCFStringEncodingUTF8);
    value = CFStringCreateWithBytes(kCFAllocatorDefault, input, input_length,
                                    kCFStringEncodingUTF8, false);
    if (target == NULL || key == NULL || value == NULL) {
        fprintf(stderr, "invalid preference target, key, or UTF-8 value\n");
        goto cleanup;
    }

    CFPreferencesSetValue(key, value, target, kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    synchronized = CFPreferencesSynchronize(target, kCFPreferencesCurrentUser,
                                            kCFPreferencesAnyHost);
    if (!synchronized) {
        fprintf(stderr, "preference synchronization failed\n");
        goto cleanup;
    }
    status = 0;

cleanup:
    if (value != NULL) {
        CFRelease(value);
    }
    if (key != NULL) {
        CFRelease(key);
    }
    if (target != NULL) {
        CFRelease(target);
    }
    if (input != NULL) {
        secure_zero(input, input_length);
        free(input);
    }
    return status;
}
