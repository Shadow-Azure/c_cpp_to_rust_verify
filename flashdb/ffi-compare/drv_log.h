/*
 * drv_log.h — redirect FlashDB's log output to stderr.
 *
 * FlashDB builds every log macro (FDB_INFO, FDB_DEBUG, FDB_LOG_PREFIX) on top
 * of FDB_PRINT, whose default definition is printf() — i.e. stdout. The
 * equivalence driver must keep stdout reserved for its own deterministic CASE
 * observation lines so the two-binary diff is not polluted by library
 * diagnostics. fdb_def.h only defines FDB_PRINT under #ifndef, so providing a
 * prior definition here makes every FlashDB log go to stderr instead.
 *
 * This file is force-included via -include before any FlashDB header.
 */
#ifndef _DRV_LOG_H_
#define _DRV_LOG_H_

#include <stdio.h>

#ifndef FDB_PRINT
#define FDB_PRINT(...) fprintf(stderr, __VA_ARGS__)
#endif

#endif /* _DRV_LOG_H_ */
