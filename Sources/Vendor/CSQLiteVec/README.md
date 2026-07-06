# CSQLiteVec Vendor Sources

This target statically compiles SQLite and sqlite-vec for the Engram local RAG
index. It intentionally does not use runtime `load_extension`.

- SQLite: official amalgamation `sqlite-amalgamation-3530300.zip`, SQLite
  3.53.3, downloaded from `https://www.sqlite.org/2026/sqlite-amalgamation-3530300.zip`.
  SQLite is public domain per `https://sqlite.org/copyright.html`.
- sqlite-vec: official release asset
  `sqlite-vec-0.1.10-alpha.4-amalgamation.zip`, source version
  `v0.1.10-alpha.4`, source commit `04d28bd21773981e2d266bbf6aa4efbd011eb4f6`,
  downloaded from `https://github.com/asg017/sqlite-vec/releases/download/v0.1.10-alpha.4/sqlite-vec-0.1.10-alpha.4-amalgamation.zip`.
  sqlite-vec is dual-licensed MIT or Apache-2.0; license texts are vendored in
  `Licenses/`.
- Vendored C files were mechanically normalized for trailing whitespace so
  repository `git diff --check` gates stay green; no code logic was changed.

SwiftPM compiles this target with `SQLITE_CORE`, `SQLITE_VEC_STATIC`,
`SQLITE_ENABLE_FTS5`, and `SQLITE_OMIT_LOAD_EXTENSION`. The sqlite-vec
amalgamation asset does not include the optional DiskANN or Rescore source
fragments, so the target also sets `SQLITE_VEC_ENABLE_DISKANN=0` and
`SQLITE_VEC_ENABLE_RESCORE=0`.
