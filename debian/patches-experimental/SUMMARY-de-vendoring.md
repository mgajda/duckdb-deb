De-vendoring experiment summary
===============================

Date: 2026-05-19
Status: RESEARCH COMPLETE -- no de-vendoring patches recommended for v1.

Goal
----

Replace bundled `third_party/` libraries (~11 of them linked into
libduckdb.so or extensions) with Debian system packages, to reduce
the MIR vendored-code maintenance burden and let Debian's security
team track CVEs centrally.

Result
------

Each library was inspected for de-vendoring viability.  Empirically,
none are "drop-in easy".

| Library  | Clean vendor? | DuckDB has Debian? | API match? | Decision |
|----------|---------------|---------------------|------------|----------|
| utf8proc | No (4 patches + custom fn) | Yes (libutf8proc-dev) | 2.9 vs 2.11 API drift | Skip |
| yyjson   | No (1 fast_mem.hpp patch)  | Yes (libyyjson-dev)   | 0.9 vs 0.12, big surface | Skip |
| zstd     | Yes                        | Yes (libzstd-dev)     | 1.5.6 vs 1.5.7 (close)   | Skip (xxhash dep) |
| mbedtls  | Yes                        | Yes (libmbedtls-dev)  | 2.x vs 3.x (big break)   | Skip (private fields) |
| miniz    | Yes                        | No (different libs)   | N/A                      | Skip (no system alt) |
| fmt      | No (8 patches)             | Yes (libfmt-dev)      | ABI churn risk           | Skip |
| re2      | Yes                        | Yes (libre2-dev)      | needs testing            | Skip (ABI churn) |
| brotli   | (extension-inlined)        | Yes                   | needs testing            | Skip (low priority) |
| lz4      | (extension-inlined)        | Yes                   | needs testing            | Skip (low priority) |
| snappy   | (extension-inlined)        | Yes                   | needs testing            | Skip (low priority) |
| thrift   | (extension-inlined)        | Yes (libthrift-dev)   | needs testing            | Skip (low priority) |

The pattern across all libraries: **DuckDB's third_party/ is not a
passive bundle — it is a fork-and-patch tree.**  Library code is
namespaced (`duckdb_zstd::`, `duckdb_yyjson::`, `namespace duckdb {}`
for utf8proc), patched with DuckDB-internal headers (yyjson uses
`duckdb/common/fast_mem.hpp`), and sometimes extended with custom
functions (`utf8proc_remove_accents`).

For a single library, the patch work is on the order of:
  - 1 CMake edit
  - 1 header shim
  - 1-3 source-side fix-ups for API drift
  - Possibly re-implement DuckDB-only functions
  - Per-distro CI verification

Total: ~50-100 LOC of patches + ~1 day per library.

For *all* libraries, the burden is comparable to (or larger than)
the MIR "vendored code refresh" commitment we were trying to avoid.

Recommendation
--------------

For v1 of this packaging: **keep the vendored copies.**  Document
the security commitment in debian/README.MIR.  Track DuckDB
upstream releases as the primary CVE-refresh mechanism (every
DuckDB minor release ships re-synced third_party/ copies from
upstream).

Per-library de-vendoring is a viable v2/v3 project but should be
justified by a specific CVE event, not done speculatively.

Files preserved
---------------

- `utf8proc-attempt/` — full working patch set + FINDINGS.md
  showing the cost surface for one library, kept as a worked
  example for future contributors.
- This SUMMARY-de-vendoring.md
