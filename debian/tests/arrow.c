/*
 * Smoke test for the Arrow C-API exposed by libduckdb.
 *
 * Runs a query, requests the result as Arrow, verifies the
 * column and row counts, then destroys the result.  We do not
 * fetch the schema or array pointers: the Arrow C Data Interface
 * ownership rules for those (consumer must invoke `release`) are
 * not directly expressible against duckdb.h's opaque typedefs,
 * and a smoke test should not gamble on which side owns the
 * memory.  The count entry points are enough to detect ABI
 * breakage in the Arrow surface.
 */

#include <duckdb.h>
#include <stdio.h>
#include <stdlib.h>

int main(void)
{
	duckdb_database db = NULL;
	duckdb_connection con = NULL;
	duckdb_arrow ar = NULL;
	int rc = 1;

	if (duckdb_open(NULL, &db) != DuckDBSuccess) {
		fprintf(stderr, "arrow: duckdb_open failed\n");
		return 1;
	}
	if (duckdb_connect(db, &con) != DuckDBSuccess) {
		fprintf(stderr, "arrow: duckdb_connect failed\n");
		goto out;
	}

	const char *q =
	    "SELECT i, i * 2 AS doubled "
	    "FROM range(0, 5) t(i)";

	if (duckdb_query_arrow(con, q, &ar) != DuckDBSuccess) {
		const char *err = ar ? duckdb_query_arrow_error(ar) : NULL;
		fprintf(stderr, "arrow: duckdb_query_arrow failed%s%s\n",
		        err ? ": " : "", err ? err : "");
		goto out;
	}

	idx_t cols = duckdb_arrow_column_count(ar);
	idx_t rows = duckdb_arrow_row_count(ar);
	if (cols != 2) {
		fprintf(stderr, "arrow: expected 2 cols, got %lld\n",
		        (long long)cols);
		goto out;
	}
	if (rows != 5) {
		fprintf(stderr, "arrow: expected 5 rows, got %lld\n",
		        (long long)rows);
		goto out;
	}

	printf("arrow: OK (%lld cols, %lld rows)\n",
	       (long long)cols, (long long)rows);
	rc = 0;

out:
	if (ar)  duckdb_destroy_arrow(&ar);
	if (con) duckdb_disconnect(&con);
	if (db)  duckdb_close(&db);
	return rc;
}
