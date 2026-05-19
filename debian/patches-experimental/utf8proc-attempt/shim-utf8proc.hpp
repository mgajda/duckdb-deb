/*
 * Debian de-vendoring shim for DuckDB.
 *
 * Replaces the vendored copy of utf8proc.h (renamed .hpp and wrapped in
 * `namespace duckdb`) with a thin shim that:
 *   1. includes the system <utf8proc.h> from libutf8proc-dev,
 *   2. re-exports the symbols and types DuckDB consumes under
 *      `namespace duckdb`, matching what the vendored header used to
 *      provide.
 *
 * If DuckDB starts using more utf8proc functions, add a corresponding
 * `using ::name;` line below.  The current set was derived by running
 *   nm --undefined-only build-test/.../libduckdb_utf8proc.a
 * against the wrapper translation unit after applying the CMake
 * de-vendoring patch.
 */

#pragma once

#include <utf8proc.h>  /* from libutf8proc-dev, /usr/include/utf8proc.h */

namespace duckdb {
    /* Functions DuckDB's utf8proc_wrapper.cpp + scalar string ops use. */
    using ::utf8proc_NFC;       /* 1-arg form in utf8proc 2.10+ */
    using ::utf8proc_map;       /* used for length-aware NFC */
    using ::utf8proc_get_property;
    using ::utf8proc_grapheme_break_stateful;
    using ::utf8proc_tolower;
    using ::utf8proc_toupper;

    /* Types referenced via duckdb::utf8proc_* in the wrapper. */
    using ::utf8proc_int32_t;
    using ::utf8proc_uint8_t;
    using ::utf8proc_ssize_t;
    using ::utf8proc_property_t;
    using ::utf8proc_category_t;
    using ::utf8proc_option_t;
}
