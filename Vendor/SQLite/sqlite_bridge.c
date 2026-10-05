#include "sqlite3.h"
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

static pthread_once_t crypt_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t crypt_mutex = PTHREAD_MUTEX_INITIALIZER;
static void *crypt_symbol = NULL;
static void *crypt_library = NULL;

static void load_crypt(void) {
#if defined(__APPLE__)
    crypt_symbol = dlsym(RTLD_DEFAULT, "crypt");
#else
    crypt_library = dlopen("libcrypt.so.1", RTLD_NOW | RTLD_LOCAL);
    crypt_symbol = crypt_library ? dlsym(crypt_library, "crypt") : NULL;
#endif
}

int campfire_sqlite_config_multithread(void) {
    return sqlite3_config(SQLITE_CONFIG_MULTITHREAD);
}

int campfire_bcrypt_verify(const char *password, const char *digest) {
    if (strncmp(digest, "$2a$", 4) != 0 || strlen(digest) != 60) return -1;
#if defined(__APPLE__)
    pthread_once(&crypt_once, load_crypt);
#else
    pthread_once(&crypt_once, load_crypt);
#endif
    if (!crypt_symbol) return -1;
    char *(*crypt_fn)(const char *, const char *) = (char *(*)(const char *, const char *))crypt_symbol;
    pthread_mutex_lock(&crypt_mutex);
    const char *actual = crypt_fn(password, digest);
    if (!actual || actual[0] == '*') {
        pthread_mutex_unlock(&crypt_mutex);
        return -1;
    }
    if (strlen(actual) != strlen(digest) || actual[0] != '$' || actual[1] != '2' || actual[3] != '$') {
        pthread_mutex_unlock(&crypt_mutex);
        return -1;
    }
    unsigned char difference = 0;
    /* libxcrypt canonicalizes bcrypt revisions to 2y; 2a and 2y share the same hash result. */
    for (size_t i = 4; i < strlen(digest); i++) difference |= (unsigned char)actual[i] ^ (unsigned char)digest[i];
    pthread_mutex_unlock(&crypt_mutex);
    return difference == 0;
}
