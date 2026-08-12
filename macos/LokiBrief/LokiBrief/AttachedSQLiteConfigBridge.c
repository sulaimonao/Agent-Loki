#include "AttachedSQLiteConfigBridge.h"
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fcntl.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <unistd.h>

int loki_attached_sqlite_db_config(
    sqlite3 *database,
    int operation,
    int value,
    int *effective_value
) {
    if (database == NULL || effective_value == NULL) {
        return SQLITE_MISUSE;
    }
    return sqlite3_db_config(database, operation, value, effective_value);
}

int loki_attached_descriptor_path(
    int descriptor,
    char *path_buffer,
    size_t path_buffer_size
) {
    if (descriptor < 0 || path_buffer == NULL || path_buffer_size < MAXPATHLEN) {
        errno = EINVAL;
        return -1;
    }
    char descriptor_path[MAXPATHLEN] = {0};
    char canonical_path[MAXPATHLEN] = {0};
    char nofollow_path[MAXPATHLEN] = {0};
    if (fcntl(descriptor, F_GETPATH, descriptor_path) != 0
        || realpath(descriptor_path, canonical_path) == NULL) {
        return -1;
    }

    const char *path_to_open = canonical_path;
    if (strncmp(canonical_path, "/var/", 5) == 0
        || strncmp(canonical_path, "/tmp/", 5) == 0
        || strncmp(canonical_path, "/etc/", 5) == 0) {
        int written = snprintf(
            nofollow_path,
            sizeof(nofollow_path),
            "/private%s",
            canonical_path
        );
        if (written < 0 || (size_t)written >= sizeof(nofollow_path)) {
            errno = ENAMETOOLONG;
            return -1;
        }
        path_to_open = nofollow_path;
    }

    int path_descriptor = open(
        path_to_open,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    );
    if (path_descriptor < 0) {
        return -1;
    }
    struct stat retained = {0};
    struct stat current = {0};
    int result = 0;
    if (fstat(descriptor, &retained) != 0
        || fstat(path_descriptor, &current) != 0
        || retained.st_dev != current.st_dev
        || retained.st_ino != current.st_ino
        || (retained.st_mode & S_IFMT) != (current.st_mode & S_IFMT)) {
        errno = ESTALE;
        result = -1;
    } else if (strlcpy(path_buffer, path_to_open, path_buffer_size)
        >= path_buffer_size) {
        errno = ENAMETOOLONG;
        result = -1;
    }
    close(path_descriptor);
    return result;
}
