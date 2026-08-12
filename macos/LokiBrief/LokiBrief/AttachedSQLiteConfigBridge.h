#ifndef AttachedSQLiteConfigBridge_h
#define AttachedSQLiteConfigBridge_h

#include <stddef.h>
#include <sqlite3.h>

int loki_attached_sqlite_db_config(
    sqlite3 *database,
    int operation,
    int value,
    int *effective_value
);

int loki_attached_descriptor_path(
    int descriptor,
    char *path_buffer,
    size_t path_buffer_size
);

#endif
