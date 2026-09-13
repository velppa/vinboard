/* Tiny C helpers to expose SQLite sentinel values that Zig cannot represent
   as typed pointer constants (SQLITE_TRANSIENT = (sqlite3_destructor_type)-1). */
#include "sqlite3.h"

int zig_sqlite3_bind_text_transient(
    sqlite3_stmt *stmt, int i, const char *text, int len)
{
    return sqlite3_bind_text(stmt, i, text, len, SQLITE_TRANSIENT);
}

int zig_sqlite3_bind_blob_transient(
    sqlite3_stmt *stmt, int i, const void *blob, int len)
{
    return sqlite3_bind_blob(stmt, i, blob, len, SQLITE_TRANSIENT);
}
