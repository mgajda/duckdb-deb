/*
 * Multithreading smoke test for libduckdb.
 *
 * Opens one in-memory database, then launches N worker threads
 * that each open their own connection and INSERT M rows tagged
 * with their thread id.  After joining, the main thread queries
 * the total row count and verifies it equals N * M.
 *
 * What this catches:
 *   - libduckdb built without pthread linkage (TLS would crash)
 *   - regression that serialises connections to a single thread
 *     and races on row counts
 *   - missing thread-safety in the catalog under concurrent DDL
 *     (we keep DDL on the main thread to avoid testing the
 *     stronger property, but row-level concurrency is exercised)
 */

#include <duckdb.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NTHREADS 4
#define NROWS_PER_THREAD 1000

struct worker_arg {
	duckdb_database db;
	int tid;
	int ok;
};

static void *worker(void *p)
{
	struct worker_arg *arg = p;
	duckdb_connection con;
	if (duckdb_connect(arg->db, &con) != DuckDBSuccess) {
		fprintf(stderr, "thread %d: connect failed\n", arg->tid);
		arg->ok = 0;
		return NULL;
	}

	char sql[128];
	for (int i = 0; i < NROWS_PER_THREAD; i++) {
		snprintf(sql, sizeof sql,
		         "INSERT INTO t VALUES (%d, %d)", arg->tid, i);
		if (duckdb_query(con, sql, NULL) != DuckDBSuccess) {
			fprintf(stderr, "thread %d: INSERT %d failed\n",
			        arg->tid, i);
			duckdb_disconnect(&con);
			arg->ok = 0;
			return NULL;
		}
	}
	duckdb_disconnect(&con);
	arg->ok = 1;
	return NULL;
}

int main(void)
{
	duckdb_database db;
	duckdb_connection main_con;

	if (duckdb_open(NULL, &db) != DuckDBSuccess) {
		fprintf(stderr, "multithread: duckdb_open failed\n");
		return 1;
	}
	if (duckdb_connect(db, &main_con) != DuckDBSuccess) {
		fprintf(stderr, "multithread: duckdb_connect failed\n");
		return 1;
	}
	if (duckdb_query(main_con,
	                 "CREATE TABLE t (tid INTEGER, i INTEGER)",
	                 NULL) != DuckDBSuccess) {
		fprintf(stderr, "multithread: CREATE TABLE failed\n");
		return 1;
	}

	pthread_t th[NTHREADS];
	struct worker_arg args[NTHREADS];
	for (int t = 0; t < NTHREADS; t++) {
		args[t].db = db;
		args[t].tid = t;
		args[t].ok = 0;
		if (pthread_create(&th[t], NULL, worker, &args[t]) != 0) {
			fprintf(stderr, "multithread: pthread_create %d failed\n", t);
			return 1;
		}
	}

	int all_ok = 1;
	for (int t = 0; t < NTHREADS; t++) {
		pthread_join(th[t], NULL);
		if (!args[t].ok) all_ok = 0;
	}
	if (!all_ok) return 1;

	duckdb_result r;
	if (duckdb_query(main_con,
	                 "SELECT count(*) FROM t",
	                 &r) != DuckDBSuccess) {
		fprintf(stderr, "multithread: SELECT count failed\n");
		return 1;
	}
	int64_t total = duckdb_value_int64(&r, 0, 0);
	duckdb_destroy_result(&r);

	int64_t expected = (int64_t)NTHREADS * NROWS_PER_THREAD;
	if (total != expected) {
		fprintf(stderr, "multithread: expected %lld rows, got %lld\n",
		        (long long)expected, (long long)total);
		return 1;
	}

	duckdb_disconnect(&main_con);
	duckdb_close(&db);
	printf("multithread: OK (%d threads x %d rows = %lld)\n",
	       NTHREADS, NROWS_PER_THREAD, (long long)total);
	return 0;
}
