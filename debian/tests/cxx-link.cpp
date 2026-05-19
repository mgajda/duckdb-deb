// C++ smoke test against duckdb.hpp.  Mirrors c-link.c but uses
// the higher-level C++ API: DuckDB / Connection / Query result
// iteration.  Verifies that the amalgamation header is usable
// and the C++ symbols resolve from libduckdb1.

#include <duckdb.hpp>
#include <cstdio>
#include <cstdlib>
#include <string>

int main() {
	duckdb::DuckDB db(nullptr);   // in-memory
	duckdb::Connection con(db);

	auto r0 = con.Query("CREATE TABLE t (id INTEGER, name VARCHAR)");
	if (r0->HasError()) { fprintf(stderr, "CREATE: %s\n", r0->GetError().c_str()); return 1; }

	auto r1 = con.Query("INSERT INTO t VALUES (1, 'alpha'), (2, 'beta')");
	if (r1->HasError()) { fprintf(stderr, "INSERT: %s\n", r1->GetError().c_str()); return 1; }

	auto r2 = con.Query("SELECT id, name FROM t ORDER BY id");
	if (r2->HasError()) { fprintf(stderr, "SELECT: %s\n", r2->GetError().c_str()); return 1; }

	if (r2->RowCount() != 2) {
		fprintf(stderr, "cxx-link: expected 2 rows, got %zu\n",
		        (size_t)r2->RowCount());
		return 1;
	}
	int32_t id0 = r2->GetValue(0, 0).GetValue<int32_t>();
	std::string name0 = r2->GetValue(1, 0).GetValue<std::string>();
	if (id0 != 1 || name0 != "alpha") {
		fprintf(stderr, "cxx-link: row 0 mismatch: id=%d name=%s\n",
		        (int)id0, name0.c_str());
		return 1;
	}

	printf("cxx-link: OK\n");
	return 0;
}
