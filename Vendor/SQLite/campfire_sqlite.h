#ifndef CAMPFIRE_SQLITE_H
#define CAMPFIRE_SQLITE_H
int campfire_sqlite_config_multithread(void);
int campfire_bcrypt_verify(const char *password, const char *digest);
#endif
