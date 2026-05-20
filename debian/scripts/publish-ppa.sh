#!/bin/sh
# publish-ppa.sh -- Generate signed source packages targeting a
# Launchpad PPA, one per Ubuntu series.  PRINTS the dput commands
# at the end; does NOT execute them.
#
# Designed to run from the maintainer's laptop.  The actual upload
# requires an unlocked SSH key + a GPG key registered on Launchpad,
# both of which are easier for the maintainer to manage by hand
# than for the script to drive (per CLAUDE.md, don't auto-loop
# around ssh-add failures).
#
# This script's contract is:
#   - Take a v* tag
#   - Produce a per-series _source.changes for each Ubuntu LTS we
#     target (currently noble; SERIES_LIST is the single source of
#     truth and can be extended when a new LTS is supported)
#   - Print the exact dput commands the maintainer should run
#
# The maintainer's job is then a copy-paste loop, with ssh-agent +
# gpg-agent already unlocked.
#
# ----------------------------------------------------------------
# Usage
# ----------------------------------------------------------------
#
#   debian/scripts/publish-ppa.sh <tag>
#
# Example:
#   debian/scripts/publish-ppa.sh v1.5.2-deb1
#
# Output: a directory of source packages under ~/.cache/duckdb-ppa-<tag>/
# and a printed list of dput commands.
#
# ----------------------------------------------------------------
# First-time setup (run ONCE per maintainer laptop)
# ----------------------------------------------------------------
#
# 1. Create a Launchpad account at https://launchpad.net/ if you
#    don't have one.  Note your Launchpad username (mgajda).
#
# 2. Upload your GPG public key to Launchpad:
#       https://launchpad.net/~/+editpgpkeys
#    Launchpad emails you a challenge encrypted to your key;
#    decrypt and submit the response to activate.
#
# 3. Sign the Launchpad Code of Conduct:
#       https://launchpad.net/codeofconduct
#    (PPA uploads are blocked until this is done.)
#
# 4. Create the PPA archive at:
#       https://launchpad.net/~mgajda/+activate-ppa
#    Name it "duckdb-deb" so the upload target becomes
#    ppa:mgajda/duckdb-deb.
#
# 5. Add an SSH key to your Launchpad account:
#       https://launchpad.net/~/+editsshkeys
#    (Used for git pushes only, not for dput.  dput uses HTTPS+GPG.)
#
# 6. Install tooling:
#       sudo apt-get install dput devscripts ubuntu-dev-tools
#
# ----------------------------------------------------------------
# Why we don't just run dput automatically
# ----------------------------------------------------------------
#
# dput's upload step expects:
#   (a) a signed _source.changes whose signature matches a key
#       known to Launchpad
#   (b) network access to ppa.launchpad.net
#   (c) an unattended, idempotent retry behaviour on transient
#       network failures
#
# (a) requires gpg-agent to be unlocked; auto-retrying on lock
# failures is a CLAUDE.md anti-pattern.  (b) and (c) are fine but
# combined with (a) make the right interaction model "tell me
# what to do" rather than "do it for me".
#
# ----------------------------------------------------------------
# Implementation
# ----------------------------------------------------------------

set -eu

# ---- 1. Argument parsing + sanity ---------------------------------

usage() {
    cat <<EOF >&2
Usage: $0 <tag>
Generates per-series source packages for the Launchpad PPA, signed
by your gpg default key, and prints the dput commands to upload them.

  <tag>    A v* git tag with an associated GitHub release.

Environment:
  PPA_NAME      Override the PPA target (default: ppa:mgajda/duckdb-deb)
  WORKDIR       Scratch dir (default: ~/.cache/duckdb-ppa-<tag>)
  SIGNING_KEY   GPG fingerprint to sign with (default: gpg default-key)
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

REPO_ROOT=$(git rev-parse --show-toplevel)
WORKDIR=${WORKDIR:-$HOME/.cache/duckdb-ppa-$tag}
PPA_NAME=${PPA_NAME:-ppa:mgajda/duckdb-deb}

# Ubuntu series we target.  Each gets its own per-series source
# package with a "~<series>0" version suffix per Debian convention
# for backports.  Add or remove series here when our compatibility
# matrix changes.
SERIES_LIST="noble"

# ---- 2. Tool availability -----------------------------------------

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '%s: required tool not found: %s\n' "$0" "$1" >&2
        printf 'install via: sudo apt-get install %s\n' "$2" >&2
        exit 2
    }
}
need dch devscripts
need dpkg-buildpackage dpkg-dev
need dput dput
need gh gh
need gpg gnupg

# ---- 3. Pre-flight checks -----------------------------------------

if ! git -C "$REPO_ROOT" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
    printf '%s: tag %s not found locally\n' "$0" "$tag" >&2
    exit 2
fi

# Refuse to publish a dirty tree -- debian/changelog gets dch'ed
# below and we don't want unrelated diffs riding along.
if ! git -C "$REPO_ROOT" diff --quiet HEAD --; then
    printf '%s: working tree has uncommitted changes; refusing to publish\n' "$0" >&2
    exit 2
fi

# Resolve the signing key.
if [ -n "${SIGNING_KEY:-}" ]; then
    gpg --list-secret-keys "$SIGNING_KEY" >/dev/null 2>&1 || {
        printf '%s: SIGNING_KEY=%s not found\n' "$0" "$SIGNING_KEY" >&2
        exit 2
    }
    KEY=$SIGNING_KEY
else
    KEY=$(gpg --list-secret-keys --keyid-format=long 2>/dev/null \
          | awk '/^sec/ {print $2; exit}' | cut -d/ -f2)
    if [ -z "$KEY" ]; then
        printf '%s: no gpg secret keys available; cannot sign\n' "$0" >&2
        exit 2
    fi
fi
printf 'signing key: %s\n' "$KEY"

# ---- 4. Set up workdir --------------------------------------------

mkdir -p "$WORKDIR"

# Make sure the source-package state from a previous run does not
# bleed into this one.  Each invocation gets a fresh checkout.
WORKTREE=$WORKDIR/src
rm -rf "$WORKTREE"

# ---- 5. For each series: checkout tag, dch backport, build, sign --

for series in $SERIES_LIST; do
    printf '\n=== preparing %s source package ===\n' "$series"

    # Fresh checkout at the tag.  We dch-modify debian/changelog in
    # this checkout WITHOUT committing -- the goal is to produce a
    # signed source package, not to mutate the upstream branch.
    rm -rf "$WORKTREE"
    git -C "$REPO_ROOT" worktree add --detach "$WORKTREE" "$tag" >/dev/null

    # Strip the leading "v" from the tag and the trailing "-debN"
    # revision (if any) to get the upstream-version part.
    upstream_version=$(git -C "$WORKTREE" describe --tags --always | sed 's/^v//')

    cd "$WORKTREE"

    # Generate the per-series version suffix.  Standard Debian
    # backports convention is "<orig>~<series>0".  The "0" is the
    # backport-revision (incremented if you re-upload to the same
    # series).
    new_version="${upstream_version}~${series}0"

    # dch -v sets the version; -D sets the Distribution.  We pass
    # --no-auto-nmu and --force-distribution to override the
    # heuristics that would otherwise reject a downgrade from
    # 1.5.2-deb1 to 1.5.2~noble0.
    DEBEMAIL=mjgajda@gmail.com DEBFULLNAME="Michal J. Gajda" \
        dch --newversion "$new_version" \
            --distribution "$series" \
            --force-distribution \
            "Backport for Ubuntu $series via debian/scripts/publish-ppa.sh."

    # Generate the orig tarball (same as the source-package CI step).
    orig_name="duckdb_${upstream_version}.orig.tar.xz"
    if [ ! -f "../$orig_name" ]; then
        git archive --format=tar HEAD \
            | tar --delete debian \
            | xz -T0 > "../$orig_name"
    fi

    # Build the signed source package.  -S = source only; -sa =
    # include the orig tarball in the upload (required for the
    # first per-series upload; harmless on later ones because dput
    # silently skips the re-upload).
    dpkg-buildpackage -S -sa -k"$KEY"

    cd "$REPO_ROOT"
    # Move the artefacts to a per-series subdir so they don't
    # collide across loop iterations.
    mkdir -p "$WORKDIR/$series"
    mv "$WORKDIR"/*.dsc "$WORKDIR"/*_source.changes \
       "$WORKDIR"/*.tar.* "$WORKDIR"/*.buildinfo \
       "$WORKDIR/$series/" 2>/dev/null || true

    # Drop the worktree so the next series starts clean.
    git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" >/dev/null
done

# ---- 6. Print the dput commands -----------------------------------

cat <<EOF

============================================================
  Source packages prepared at:
    $WORKDIR/

  To upload, run these commands once your gpg-agent is unlocked:
EOF

for series in $SERIES_LIST; do
    changes_file=$(find "$WORKDIR/$series" -name '*_source.changes' | head -1)
    [ -n "$changes_file" ] || continue
    printf '\n    dput %s %s\n' "$PPA_NAME" "$changes_file"
done

cat <<EOF

  After dput accepts, monitor build status at:
    https://launchpad.net/~mgajda/+archive/ubuntu/duckdb-deb/+packages

  Each (series, arch) builder takes 10-60 min on Launchpad.  Failures
  there mean Debian's archive autobuilders would also fail; treat
  them as the real signal.
============================================================
EOF
