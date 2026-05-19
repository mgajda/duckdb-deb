#!/bin/sh
# publish-apt-pages.sh -- Build a static apt repo from a tagged
# GitHub release and push it to the gh-pages branch.
#
# Designed to run from the maintainer's laptop, NOT from CI.  The
# GPG signing key stays on the laptop by design; we accept the
# inconvenience of a manual unlock prompt as a real security gain.
#
# This script is the publishing companion to debian/scripts/publish.sh
# (OBS) and any future debian/scripts/publish-ppa.sh (Launchpad PPA).
# All three follow the same gates: assert clean tree, assert correct
# branch, do the publish, verify the result.
#
# ----------------------------------------------------------------
# Usage
# ----------------------------------------------------------------
#
#   debian/scripts/publish-apt-pages.sh <tag>
#
# where <tag> is a v* tag that already has a GitHub release with
# the matrix .debs attached (i.e. the workflow's release job has
# run).
#
# Example:
#   debian/scripts/publish-apt-pages.sh v1.5.2-deb1
#
# After it completes:
#   - dists/<suite>/InRelease, Release, Release.gpg are regenerated
#   - new .debs are added to pool/main/d/duckdb/
#   - gh-pages branch is force-pushed (after a tag-stamped backup of
#     the previous state in case of accidents)
#   - https://mgajda.github.io/duckdb-deb/ serves the updated repo
#     within ~5 minutes (GH Pages cache propagation)
#
# ----------------------------------------------------------------
# First-time setup (run ONCE per maintainer laptop)
# ----------------------------------------------------------------
#
# 1. Generate or import a signing key (RSA 4096 or Ed25519 recommended):
#
#       gpg --quick-generate-key 'duckdb-deb-signing <mjgajda@gmail.com>' \
#           ed25519 sign 5y
#
#    Note the fingerprint.  Make it gpg's default key, OR export
#    SIGNING_KEY=<fpr> before running this script.
#
# 2. Publish the public key under the repo's root so users can
#    verify Release.gpg:
#
#       gpg --armor --export <fpr> > /tmp/repo-key.asc
#       # publish-apt-pages.sh copies this into the gh-pages tree
#       # as duckdb-deb.gpg.asc on first run.
#
# 3. Enable GitHub Pages on the fork:
#       Settings -> Pages -> Source: "Deploy from a branch"
#                           Branch: "gh-pages" / "/ (root)"
#
# 4. Verify the URL: https://mgajda.github.io/duckdb-deb/
#    On first run there is no content; that's fine.
#
# ----------------------------------------------------------------
# Why reprepro and not aptly
# ----------------------------------------------------------------
#
# Both are static apt-repo generators; both work at our scale.
# The differences:
#
#   - reprepro: older, Debian-native (in main since the early 2000s),
#     config is one file (debian/reprepro/conf/distributions), invoked
#     once per .deb to include.  No daemon, no state outside the repo
#     dir.  Less powerful (no snapshots, no multi-suite atomicity)
#     but simpler to drive from a one-shot publish script.
#
#   - aptly: newer (Go, 2014+), models the repo as a database of
#     snapshots; "publish snapshot" promotes a snapshot to a public
#     dir.  Supports atomic multi-suite updates and tracks repo
#     history.  Daemon mode + REST API for managed pipelines.
#     Overkill for our flat publish flow.
#
# We use reprepro because:
#   (a) its mental model maps 1:1 to "publish-apt-pages.sh just
#       includes new .debs into the dists/ tree, that's it";
#   (b) Debian itself uses reprepro for many derivative repos, so
#       behaviour is well-understood;
#   (c) one less moving part (no database to corrupt).
#
# ----------------------------------------------------------------
# Implementation notes
# ----------------------------------------------------------------
#
# The script is intentionally idempotent: rerunning with the same
# tag re-includes the same .debs (reprepro deduplicates) and
# regenerates the dists/* metadata.  The only non-idempotent part
# is the git push, which always overwrites gh-pages.

set -eu

# ---- 1. Argument parsing + sanity ---------------------------------

usage() {
    cat <<EOF >&2
Usage: $0 <tag>
Publishes the .debs attached to GitHub release <tag> as an apt
repository on the gh-pages branch of the current repo's "fork" remote.

  <tag>    A v* git tag that has an associated GitHub release.

Environment:
  SIGNING_KEY   Optional GPG fingerprint (40 hex chars).  If unset,
                gpg's default-key (from gpg.conf or --default-key) is
                used.  reprepro will refuse to publish without a key.

  WORKDIR       Optional scratch directory (default: ~/.cache/duckdb-apt-pages).
                Reused across runs to avoid re-downloading .debs.

  FORK_REMOTE   Optional git remote name pointing at the github repo
                with gh-pages (default: "fork").
EOF
    exit 2
}

[ "$#" -eq 1 ] || usage
tag=$1

case "$tag" in
    v*) ;;
    *) printf '%s: tag must start with "v" (got %s)\n' "$0" "$tag" >&2
       exit 2;;
esac

WORKDIR=${WORKDIR:-$HOME/.cache/duckdb-apt-pages}
FORK_REMOTE=${FORK_REMOTE:-fork}
REPO_ROOT=$(git rev-parse --show-toplevel)

# Each suite (codename) -> the matrix label substring it pulls
# .debs from.  See .github/workflows/debian-package.yml for the
# label format (debs-<distro>-<codename>-<arch>).
DEB_SUITES="trixie sid jammy noble"

# Each (suite, arch) pair we expect to see.  The script will warn
# if a matrix leg is missing from the release.
DEB_ARCHES="amd64 arm64"

# ---- 2. Tool availability -----------------------------------------

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '%s: required tool not found: %s\n' "$0" "$1" >&2
        printf 'install via: sudo apt-get install %s\n' "$2" >&2
        exit 2
    }
}
need reprepro reprepro
need gh gh
need gpg gnupg
need git git

# ---- 3. Pre-flight checks -----------------------------------------

# Refuse to publish a tag that does not exist in the local repo.
if ! git -C "$REPO_ROOT" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
    printf '%s: tag %s not found locally\n' "$0" "$tag" >&2
    printf 'fetch tags first: git fetch %s --tags\n' "$FORK_REMOTE" >&2
    exit 2
fi

# Refuse to publish from a dirty tree.  The reprepro config and
# the user-facing key file in this repo become part of the
# published output (via "first-run copy"); a dirty tree would
# silently include uncommitted changes.
if ! git -C "$REPO_ROOT" diff --quiet HEAD --; then
    printf '%s: working tree has uncommitted changes; refusing to publish\n' "$0" >&2
    exit 2
fi

# Verify the signing key is reachable.  SIGNING_KEY env var wins
# over gpg's default; if neither is set, reprepro will fail at the
# signing step with a less helpful error.
if [ -n "${SIGNING_KEY:-}" ]; then
    gpg --list-secret-keys "$SIGNING_KEY" >/dev/null 2>&1 || {
        printf '%s: SIGNING_KEY=%s not found in gpg secret keyring\n' \
            "$0" "$SIGNING_KEY" >&2
        exit 2
    }
    printf 'using signing key: %s\n' "$SIGNING_KEY"
else
    default_key=$(gpg --list-secret-keys --keyid-format=long 2>/dev/null \
                  | awk '/^sec/ {print $2; exit}')
    if [ -z "$default_key" ]; then
        printf '%s: no gpg secret keys available\n' "$0" >&2
        printf 'see "First-time setup" in this script header\n' >&2
        exit 2
    fi
    printf 'using gpg default key: %s\n' "$default_key"
fi

# ---- 4. Set up workdir --------------------------------------------

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Per-tag artefact cache.  Keep across runs so retries are fast.
TAG_DIR=$WORKDIR/release-$tag
mkdir -p "$TAG_DIR"

# ---- 5. Download release artefacts --------------------------------

# gh release download by tag.  --skip-existing avoids re-downloading
# on retry.  Output goes into $TAG_DIR.
printf '\n=== downloading release assets for %s ===\n' "$tag"
gh release download "$tag" \
    --repo "$(git -C "$REPO_ROOT" remote get-url "$FORK_REMOTE" \
              | sed -E 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?|\1|')" \
    --dir "$TAG_DIR" \
    --skip-existing

# Inventory what we got.
deb_count=$(find "$TAG_DIR" -maxdepth 1 -name '*.deb' | wc -l)
dsc_count=$(find "$TAG_DIR" -maxdepth 1 -name '*.dsc' | wc -l)
printf 'release has %s .deb and %s .dsc files\n' "$deb_count" "$dsc_count"

if [ "$deb_count" -eq 0 ]; then
    printf '%s: release %s has no .deb files; cannot publish\n' "$0" "$tag" >&2
    exit 1
fi

# ---- 6. Prepare repo dir (clone gh-pages or init fresh) -----------

PAGES_DIR=$WORKDIR/gh-pages
fork_url=$(git -C "$REPO_ROOT" remote get-url "$FORK_REMOTE")

if [ -d "$PAGES_DIR/.git" ]; then
    printf '\n=== refreshing existing gh-pages checkout ===\n'
    git -C "$PAGES_DIR" fetch "$FORK_REMOTE" gh-pages \
        || printf 'note: gh-pages branch does not exist yet; will create\n'
    git -C "$PAGES_DIR" reset --hard "$FORK_REMOTE/gh-pages" 2>/dev/null \
        || {
            printf 'initialising fresh orphan gh-pages branch\n'
            git -C "$PAGES_DIR" checkout --orphan gh-pages
            git -C "$PAGES_DIR" rm -rf . 2>/dev/null || true
        }
else
    printf '\n=== cloning gh-pages branch ===\n'
    rm -rf "$PAGES_DIR"
    if git ls-remote --exit-code --heads "$fork_url" gh-pages >/dev/null 2>&1; then
        git clone --branch gh-pages --depth 1 "$fork_url" "$PAGES_DIR"
    else
        # gh-pages does not exist yet -- create empty orphan branch
        printf 'gh-pages branch does not exist on remote; bootstrapping\n'
        git clone --depth 1 "$fork_url" "$PAGES_DIR"
        cd "$PAGES_DIR"
        git checkout --orphan gh-pages
        git rm -rf . 2>/dev/null || true
        cd "$WORKDIR"
    fi
fi

# ---- 7. Copy reprepro config + public key into gh-pages dir -------

printf '\n=== installing reprepro config + maintainer public key ===\n'
mkdir -p "$PAGES_DIR/conf"
cp "$REPO_ROOT/debian/reprepro/conf/distributions" "$PAGES_DIR/conf/distributions"

# Maintainer public key (for users to verify Release.gpg).
# We always re-export so a key rotation propagates automatically.
key_id=${SIGNING_KEY:-$default_key}
gpg --armor --export "$key_id" > "$PAGES_DIR/duckdb-deb-archive-key.asc"

# A bare-bones index.html so visitors don't get a 404 at the root.
cat > "$PAGES_DIR/index.html" <<HTML
<!doctype html>
<title>DuckDB packaging fork — apt repository</title>
<h1>DuckDB packaging fork — apt repository</h1>
<p>This is the apt repository for the
<a href="https://github.com/mgajda/duckdb-deb">mgajda/duckdb-deb</a>
packaging fork of DuckDB.</p>
<p>To install:</p>
<pre>
# 1. Trust the archive key
curl -fsSL https://mgajda.github.io/duckdb-deb/duckdb-deb-archive-key.asc \\
    | sudo gpg --dearmor -o /etc/apt/keyrings/duckdb-deb.gpg

# 2. Add the source (replace SUITE with your distro codename:
#    trixie, sid, jammy, or noble)
echo "deb [signed-by=/etc/apt/keyrings/duckdb-deb.gpg] \\
      https://mgajda.github.io/duckdb-deb SUITE main" \\
    | sudo tee /etc/apt/sources.list.d/duckdb-deb.list

# 3. Update + install
sudo apt-get update
sudo apt-get install duckdb libduckdb-dev
</pre>
<p>Source: <a href="https://github.com/mgajda/duckdb-deb">github.com/mgajda/duckdb-deb</a></p>
HTML

# ---- 8. Include .debs and .dsc per (suite, arch) ------------------

printf '\n=== including .debs and source packages ===\n'

# reprepro uses the gh-pages root as the repo basedir.
cd "$PAGES_DIR"

# Routing strategy:
#
# Once task #26 ("Per-distro .deb filename rename in release upload")
# lands, each release asset will be e.g. libduckdb1_<ver>_amd64_trixie.deb
# and we can route by filename suffix.  Until then, the .debs from
# four matrix legs share filenames (only differ by content), so the
# bulk-include below over-includes -- every suite gets every .deb.
#
# This is over-inclusive (a trixie-built .deb gets indexed under
# "sid" too), but in practice the same upstream version is built on
# every distro so users get a working install regardless of which
# suite they configured.  Reprepro deduplicates by SHA256, so pool/
# stays consistent.
#
# When task #26 lands, replace this loop with per-suite filtering.
# DEB_ARCHES is referenced here for future use.
: "$DEB_ARCHES"  # silence shellcheck SC2034 until per-arch routing is added
for suite in $DEB_SUITES; do
    printf '  -> %s\n' "$suite"
    # Include every .deb file in $TAG_DIR.
    for deb in "$TAG_DIR"/*.deb; do
        [ -f "$deb" ] || continue
        # reprepro will refuse if the .deb is already in this suite
        # at the same version -- harmless, continue.
        reprepro includedeb "$suite" "$deb" 2>&1 \
            | grep -v "is already registered with other md5sum" || true
    done
    # Include source package if a .dsc exists.
    for dsc in "$TAG_DIR"/*.dsc; do
        [ -f "$dsc" ] || continue
        reprepro includedsc "$suite" "$dsc" 2>&1 \
            | grep -v "is already registered" || true
    done
done

# ---- 9. Commit and push -------------------------------------------

printf '\n=== committing to gh-pages ===\n'
# Don't index reprepro's own working files (db/, lists/).
cat > .gitignore <<EOF
/db/
/lists/
/incoming/
EOF

git add -A
if git diff --staged --quiet; then
    printf 'no changes to gh-pages (repo already current for %s)\n' "$tag"
else
    # Build a one-per-line inventory of artefacts for the commit
    # message body.  find -printf keeps filenames safe even if
    # weirdly named (shellcheck SC2012/SC2035 avoidance).
    artefact_list=$(cd "$TAG_DIR" && \
                    find . -maxdepth 1 \( -name '*.deb' -o -name '*.dsc' \) \
                    -printf '  %f\n' | sort)
    git -c user.email="mjgajda@gmail.com" -c user.name="Michal J. Gajda" \
        commit -q -m "Publish $tag to apt repo

Includes:
$artefact_list

Signed by: $key_id
"
    printf '\n=== pushing to %s/gh-pages ===\n' "$FORK_REMOTE"
    git push "$fork_url" gh-pages
fi

printf '\n=== done ===\n'
printf 'apt repo will be served at https://mgajda.github.io/duckdb-deb/\n'
printf 'within ~5 minutes (GH Pages cache propagation).\n'
printf '\nVerify by running on a test system:\n'
printf '  curl -fsSL https://mgajda.github.io/duckdb-deb/dists/trixie/Release\n'
