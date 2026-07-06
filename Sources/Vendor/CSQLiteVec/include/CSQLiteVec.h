#ifndef ENGRAM_CSQLITEVEC_H
#define ENGRAM_CSQLITEVEC_H

#include "sqlite3.h"
#include "sqlite-vec.h"

#ifdef __cplusplus
extern "C" {
#endif

int engram_sqlite_vec_register(sqlite3 *db);
const char *engram_sqlite_vec_version(void);
const char *engram_sqlite_version(void);

#ifdef __cplusplus
}
#endif

#endif
