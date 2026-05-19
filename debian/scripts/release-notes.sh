#!/bin/sh
# release-notes.sh — emit Markdown release notes for a tagged build.
#
# Called by the `release` job in .github/workflows/debian-package.yml
# when a v* tag is pushed.  Stdout is fed to `gh release create
# --notes-file -`, so write only the notes body here.
#
# Two inputs, both required, as positional arguments:
#   $1  tag (e.g. v1.5.2-deb1)
#   $2  path to the release-assets/ directory containing all .deb,
#       .changes, .buildinfo, .dsc and orig.tar.* files downloaded
#       from the matrix workflow artefacts.
#
# Why a script and not an inline heredoc in the workflow YAML:
#   - the notes are reviewable in git (diff like any other source)
#   - render logic stays out of YAML escaping
#   - can be invoked locally to preview what a release page will look
#     like before pushing the tag.  Example:
#       debian/scripts/release-notes.sh v1.5.2-deb1 ./artefacts/

set -eu

tag=${1:?usage: release-notes.sh <tag> <release-assets-dir>}
assets=${2:?usage: release-notes.sh <tag> <release-assets-dir>}

# The .changes file is the canonical metadata source -- one per
# matrix leg, all sharing the same upstream version.  Pull a single
# distro's .changes to extract the version.
changes=$(find "$assets" -maxdepth 1 -name 'duckdb_*.changes' -not -name '*_source.changes' | head -n1)
if [ -z "$changes" ]; then
    printf 'release-notes.sh: no .changes file under %s\n' "$assets" >&2
    exit 2
fi
version=$(awk '/^Version:/ {print $2; exit}' "$changes")

cat <<EOF
DuckDB ${version} Debian/Ubuntu packaging — release **${tag}**.

## What's in this release

Five binary packages, built from one source on each supported
distribution.  Pick the .deb whose filename matches your distro
(see *Supported distributions* below), then install with
\`sudo apt install ./<file>.deb\`.

| Package | Purpose |
|---|---|
| \`libduckdb1\` | Shared library (\`libduckdb.so.1\`) — required at runtime |
| \`libduckdb-dev\` | Headers, \`.so\` symlink, CMake config, C-API example |
| \`duckdb\` | Command-line shell |
| \`libduckdb1-dbgsym\` | Detached debug symbols for libduckdb1 (optional) |
| \`duckdb-dbgsym\` | Detached debug symbols for the CLI (optional) |

Static archives (\`libduckdb_static.a\`) are deliberately not
shipped; users should link against the shared library.

## Supported distributions

This release was built and \`autopkgtest\`-verified on:

- **Debian trixie** (amd64)
- **Debian sid** (amd64)
- **Ubuntu 22.04 jammy** (amd64)
- **Ubuntu 24.04 noble** (amd64)

The same source built a single set of binary packages -- the
matrix exists to verify that each distribution's toolchain produces
working artefacts, not to ship per-distribution binaries.  Newer
distributions (Ubuntu 26.04, Debian forky) will be added once
container images are available.

EOF

cat <<EOF

## Quick install

\`\`\`sh
# 1. Download the three binary packages for your distro
curl -LO https://github.com/mgajda/duckdb-deb/releases/download/${tag}/libduckdb1_${version}_amd64.deb
curl -LO https://github.com/mgajda/duckdb-deb/releases/download/${tag}/libduckdb-dev_${version}_amd64.deb
curl -LO https://github.com/mgajda/duckdb-deb/releases/download/${tag}/duckdb_${version}_amd64.deb

# 2. Install (apt resolves the libduckdb1 dependency of -dev and duckdb)
sudo apt install ./libduckdb1_${version}_amd64.deb \\
                  ./libduckdb-dev_${version}_amd64.deb \\
                  ./duckdb_${version}_amd64.deb

# 3. Verify
duckdb --version
\`\`\`

## Source package

The matching \`.dsc\` + orig tarball are attached for reproducibility.
See \`debian/README.source\` in the source tree for the rebuild
recipe.

## More info

- Installation guide: [debian/README.distribution](https://github.com/mgajda/duckdb-deb/blob/debian/latest/debian/README.distribution)
- Source / packaging bugs: <https://github.com/mgajda/duckdb-deb/issues>
- Bugs in DuckDB itself: <https://github.com/duckdb/duckdb/issues>
- Upstream project: <https://duckdb.org/>

---

*Automated build of [\`${tag}\`](https://github.com/mgajda/duckdb-deb/releases/tag/${tag}).  Built and tested by GitHub Actions; not signed by an individual GPG key.  Transport integrity guaranteed by GitHub; for stronger guarantees rebuild from source.*
EOF
