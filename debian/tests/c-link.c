/*
 * Smoke test for libduckdb-dev C API.  Opens an in-memory
 * database, creates a table, inserts a row, queries it back,
 * verifies the result, and tears down cleanly.  All return codes
 * are checked; any deviation prints to stderr and exits non-zero.
 */

#include <duckdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(const char *what)
{
	fprintf(stderr, "c-link: %s\n", what);
	return 1;
}

int main(void)
{
	duckdb_database db;
	duckdb_connection con;
	duckdb_result result;

	if (duckdb_open(NULL, &db) != DuckDBSuccess)
		return fail("duckdb_open failed");
	if (duckdb_connect(db, &con) != DuckDBSuccess)
		return fail("duckdb_connect failed");

	if (duckdb_query(con, "CREATE TABLE t (id INTEGER, name VARCHAR)",
	                 NULL) != DuckDBSuccess)
		return fail("CREATE TABLE failed");

	if (duckdb_query(con,
	                 "INSERT INTO t VALUES (1, 'alpha'), (2, 'beta')",
	                 NULL) != DuckDBSuccess)
		return fail("INSERT failed");

	if (duckdb_query(con, "SELECT id, name FROM t ORDER BY id",
	                 &result) != DuckDBSuccess)
		return fail("SELECT failed");

	idx_t rows = duckdb_row_count(&result);
	if (rows != 2) {
		fprintf(stderr, "c-link: expected 2 rows, got %lld\n",
		        (long long)rows);
		duckdb_destroy_result(&result);
		return 1;
	}

	int32_t id0 = duckdb_value_int32(&result, 0, 0);
	char *name0 = duckdb_value_varchar(&result, 1, 0);
	if (id0 != 1 || !name0 || strcmp(name0, "alpha") != 0) {
		fprintf(stderr, "c-link: row 0 mismatch: id=%d name=%s\n",
		        (int)id0, name0 ? name0 : "(null)");
		duckdb_free(name0);
		duckdb_destroy_result(&result);
		return 1;
	}
	duckdb_free(name0);

	duckdb_destroy_result(&result);
	duckdb_disconnect(&con);
	duckdb_close(&db);

	printf("c-link: OK\n");
	return 0;
}
