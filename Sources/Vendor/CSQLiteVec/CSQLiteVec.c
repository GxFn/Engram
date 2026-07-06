#include "CSQLiteVec.h"

int engram_sqlite_vec_register(sqlite3 *db) {
  return sqlite3_vec_init(db, 0, 0);
}

const char *engram_sqlite_vec_version(void) {
  return SQLITE_VEC_VERSION;
}

const char *engram_sqlite_version(void) {
  return SQLITE_VERSION;
}
