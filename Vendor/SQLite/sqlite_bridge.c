#include "sqlite3.h"

int campfire_sqlite_config_multithread(void) {
    return sqlite3_config(SQLITE_CONFIG_MULTITHREAD);
}
