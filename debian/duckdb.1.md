% DUCKDB(1)

# NAME

duckdb - in-process analytical SQL database command-line shell

# SYNOPSIS

**duckdb** \[*OPTIONS*\] *FILENAME* \[*SQL*\]

# DESCRIPTION

**duckdb** is the command-line shell for DuckDB, an in-process SQL OLAP
database management system with a vectorised execution engine, columnar
storage and broad support for the SQL standard.

*FILENAME* is the path to a DuckDB database file.  A new database is
created if the file does not previously exist.  If *SQL* is given, the
shell runs that statement and exits; otherwise it enters its interactive
REPL.

# OPTIONS

`-ascii`
:   Set output mode to *ascii*.

`-bail`
:   Stop after hitting an error.

`-batch`
:   Force batch I/O.

`-box`, `-column`, `-csv`, `-html`, `-json`, `-jsonlines`, `-line`, `-list`, `-markdown`, `-quote`, `-table`
:   Set output mode to the named format.

`-c` *COMMAND*, `-s` *COMMAND*
:   Run *COMMAND* and exit.

`-cmd` *COMMAND*
:   Run *COMMAND* before reading stdin.

`-echo`
:   Print commands before execution.

`-f` *FILENAME*
:   Read and process the named file, then exit.

`-format`
:   Format SQL from standard input, writing the result to standard output.

`-format-file` *FILENAME*
:   Format SQL in *FILENAME*, writing the result to standard output.

`-h`, `-help`
:   Show help message and exit.

`-header`, `-noheader`
:   Turn column headers on or off.

`-init` *FILENAME*
:   Read and process the named init file.

`-interactive`
:   Force interactive I/O.

`-newline` *SEP*
:   Set output row separator.  Default: `\n`.

`-no-init`
:   Skip processing the init file.

`-no-stdin`
:   Exit after processing options instead of reading standard input.

`-nullvalue` *TEXT*
:   Set the string used to display SQL NULL values.  Default: *NULL*.

`-readonly`
:   Open the database in read-only mode.

`-safe`
:   Enable safe mode.

`-separator` *SEP*
:   Set output column separator.  Default: `|`.

`-storage-version` *VER*
:   Database storage compatibility version.  Default: `v0.10.0`.

`-ui`
:   Launch the web UI extension (configurable with `.ui_command`).

`-unredacted`
:   Allow printing unredacted secrets.

`-unsigned`
:   Allow loading of unsigned extensions.

`-version`
:   Show DuckDB version and exit.

# EXAMPLES

Open or create a database file and enter the interactive shell:

    duckdb mydata.duckdb

Run a single query against an in-memory database:

    duckdb -c "SELECT 42"

Query a Parquet file directly without persisting state:

    duckdb -c "SELECT count(*) FROM read_parquet('data.parquet')"

# FILES

*~/.duckdbrc*
:   User-level shell initialisation file, read on start unless `-no-init`
    is given.  May also be supplied via `-init`.

# SEE ALSO

The DuckDB documentation at <https://duckdb.org/docs/> and the SQL
reference at <https://duckdb.org/docs/sql/introduction>.

# REPORTING BUGS

Report bugs at <https://github.com/duckdb/duckdb/issues>.

# COPYRIGHT

DuckDB is Copyright (C) 2018-2026 Stichting DuckDB Foundation,
distributed under the MIT license.
