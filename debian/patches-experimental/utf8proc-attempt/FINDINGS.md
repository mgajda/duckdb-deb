utf8proc de-vendoring experiment — findings
============================================

Date: 2026-05-19
Status: DEFERRED -- patch works but cost-benefit is poor.

Goal
----

Replace the vendored `third_party/utf8proc/` copy (~2.2 MB Unicode
tables + ~36 KB code) with a link against Debian's `libutf8proc-dev`
(libutf8proc.so.3.2.3, source-version 2.11.3-2).

Method
------

1. Apply `01-cmake-system-utf8proc.patch` to
   `third_party/utf8proc/CMakeLists.txt`: stop compiling `utf8proc.cpp`
   and `utf8proc_data.cpp` (the Unicode tables), add
   `pkg_check_modules(... libutf8proc)`, link the still-compiled
   `utf8proc_wrapper.cpp` against the system library via
   `target_link_libraries(duckdb_utf8proc PUBLIC PkgConfig::SYSTEM_UTF8PROC)`.

2. Replace `third_party/utf8proc/include/utf8proc.hpp` with
   `shim-utf8proc.hpp`, which `#include <utf8proc.h>` from the system
   and pulls the symbols DuckDB references into `namespace duckdb`
   via `using ::name;` lines.

3. Apply `02-wrapper-api-changes.patch` to
   `third_party/utf8proc/utf8proc_wrapper.cpp` to rewrite
   `Utf8Proc::Normalize` to use `utf8proc_map(...,
   UTF8PROC_STABLE|UTF8PROC_COMPOSE)` because system utf8proc 2.11.3's
   `utf8proc_NFC()` no longer takes a length parameter (the
   vendored 2.9.0 version did).

What works
----------

- CMake configure succeeds; `pkg_check_modules` finds the system
  library.
- `duckdb_utf8proc.a` (static archive of the wrapper TU) builds
  cleanly.
- Symbol-resolution check confirms all `utf8proc_*` symbols
  imported by `duckdb_utf8proc.a` are exported by
  `/usr/lib/x86_64-linux-gnu/libutf8proc.so.3.2.3`.

What doesn't (and would need more patches)
------------------------------------------

The full `libduckdb.so` link surfaced TWO additional issues that the
shim above does not address:

1. `utf8proc_remove_accents()` — A DuckDB-ADDED function that does
   not exist in upstream utf8proc.  Defined in
   `third_party/utf8proc/utf8proc.cpp:804` as a 5-line wrapper:
       utf8proc_map(str, len, &retval, UTF8PROC_STABLE
                    | UTF8PROC_COMPOSE | UTF8PROC_STRIPMARK).
   Used by `src/function/scalar/string/strip_accents.cpp`.
   De-vendoring would require either moving this wrapper into
   `utf8proc_wrapper.cpp` (DuckDB code) or patching the caller to
   inline the `utf8proc_map` call directly.

2. `utf8proc_NFKD(str, len)` — Same API drift as `utf8proc_NFC`:
   system 2.11.3 takes only `(str)` (NUL-terminated), but
   `src/execution/operator/csv_scanner/sniffer/header_detection.cpp`
   calls it with `(str, len)`.  Fix: rewrite the call to use
   `utf8proc_map(..., UTF8PROC_DECOMPOSE | UTF8PROC_COMPAT)` which
   is what NFKD expands to internally.

Total patch surface to actually complete de-vendoring: ~70 LOC
across 4 files.

Decision
--------

**Skip utf8proc de-vendoring for now.**

Reasons:
- utf8proc has ZERO known CVEs in upstream history -- low security
  payoff for the patch maintenance burden.
- DuckDB has actively extended the vendored copy with custom
  functions (`utf8proc_remove_accents`), suggesting they treat it
  as forked-and-maintained, not as a passive vendor.
- The 2.9 -> 2.11 API drift (NFC/NFKD signature change) shows
  that upstream utf8proc does break public APIs across minor
  versions; future security updates by Debian could re-break the
  de-vendoring patch without warning.
- ~2.2 MB of static Unicode tables in libduckdb.so is not a
  significant cost on a 17 MB library.

What would change this calculus:
- A new CVE in utf8proc (re-evaluate)
- Upstream DuckDB removing the custom `utf8proc_remove_accents`
  function (probably never)
- Debian shipping utf8proc 3.x with the wrappers DuckDB needs
  upstream (unlikely)

Re-running the experiment
-------------------------

The three patch files in this directory are kept for reference:
  01-cmake-system-utf8proc.patch   modify third_party/utf8proc/CMakeLists.txt
  02-wrapper-api-changes.patch     fix Utf8Proc::Normalize NFC call
  shim-utf8proc.hpp                replacement for utf8proc.hpp

To resume:
  git apply debian/patches-experimental/utf8proc-attempt/01-cmake-system-utf8proc.patch
  git apply debian/patches-experimental/utf8proc-attempt/02-wrapper-api-changes.patch
  cp debian/patches-experimental/utf8proc-attempt/shim-utf8proc.hpp \
     third_party/utf8proc/include/utf8proc.hpp
  # then add: utf8proc_remove_accents() impl + utf8proc_NFKD fix
