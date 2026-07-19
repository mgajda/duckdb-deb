#!/bin/bash
# Background deb package build with resource limits.
# Run: nohup bash tmp/build-deb.sh &
# Tail: tail -f tmp/build-deb.log

set -eu
cd /home/m/src/duckdb

LOGFILE=tmp/build-deb.log
exec > "$LOGFILE" 2>&1

echo "=== $(date) Starting DuckDB deb build ==="
echo "CPU cores: $(nproc)"
echo "Memory:"
free -h
echo "Disk:"
df -h /home/m/src/duckdb

# Clean any previous build artifacts
rm -rf build/deb
rm -f ../*.deb ../*.ddeb ../*.changes ../*.buildinfo ../*.tar.* ../*.dsc

# Build with constrained parallelism under low priority
# parallel=2: ~4 GB RSS during compile, safe with 10 GiB available
export DEB_BUILD_OPTIONS="parallel=2"
export DEB_BUILD_MAINT_OPTIONS="hardening=+all"

# TMPDIR: LTO link creates massive temp files (~12+ GiB for a 13 GiB
# libduckdb_static.a).  The default /tmp is 15 GiB tmpfs and overflows.
# Point it at the 392 GiB ZFS pool via tmp/.
# LTO temp files (overflows 15 GiB /tmp tmpfs)
export TMPDIR=/home/m/src/duckdb/tmp/lto-tmp
export TMP=/home/m/src/duckdb/tmp/lto-tmp
export TEMP=/home/m/src/duckdb/tmp/lto-tmp
mkdir -p "$TMPDIR"

echo "=== $(date) Starting dpkg-buildpackage ==="
nice -n 19 ionice -c3 dpkg-buildpackage -us -uc -b

rc=$?
echo "=== $(date) dpkg-buildpackage exit code: $rc ==="

if [ $rc -eq 0 ]; then
    echo "=== Build succeeded! Artefacts: ==="
    ls -lh ../*.deb ../*.changes ../*.buildinfo 2>/dev/null || true
else
    echo "=== Build FAILED ==="
    # Show last 50 lines of build log for diagnostics
    tail -50 "$LOGFILE"
fi

echo "=== $(date) Build script finished ==="
