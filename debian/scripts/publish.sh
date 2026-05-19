#!/bin/sh
# publish.sh — sync the canonical _service from git into the OBS
# package home:mjgajda/duckdb and (optionally) wait for the build
# matrix to finish.
#
# Designed to run from the maintainer's laptop, NOT from CI.  CI
# does not have OBS credentials by design — publishing is a
# deliberate, signed-off-by-a-human step.
#
# Prerequisites:
#   - osc(1) installed and configured (~/.config/osc/oscrc with a
#     valid OBS login).  See debian/README.OBS.
#   - This script run from the top of the duckdb git working tree,
#     on branch debian/latest, with the tree clean (no uncommitted
#     changes that would silently differ from what OBS will fetch
#     via tar_scm).
#   - The git tag or branch named in debian/obs/_service's <revision>
#     pushed to github.com/mjgajda/duckdb already; OBS pulls from
#     GitHub, not from your laptop.
#
# Modes (default: dry-run check):
#   publish.sh              show drift between git and OBS, exit 0 if
#                           clean, exit 1 if drift.
#   publish.sh --push       sync local debian/obs/_service into OBS
#                           and run the source services.  Triggers a
#                           build matrix run.
#   publish.sh --push --wait
#                           ...then block until osc results reports
#                           every target as finished.  Non-zero exit
#                           if any target failed.
#   publish.sh --pull       overwrite local debian/obs/_service with
#                           whatever is currently in OBS.  Use this
#                           after someone has hand-edited via the web
#                           UI and you want to bring git into sync.
#
# Exit codes:
#   0   success / no drift
#   1   drift detected (in --check) or build failure (in --wait)
#   2   precondition not met (wrong branch, dirty tree, missing osc...)

set -eu

PROJECT=home:mjgajda
PACKAGE=duckdb
CANONICAL_SERVICE=debian/obs/_service
WORKDIR=${OBS_WORKDIR:-$HOME/.cache/duckdb-obs}

mode=check
wait_for_build=0
for arg in "$@"; do
    case "$arg" in
        --push)  mode=push ;;
        --pull)  mode=pull ;;
        --wait)  wait_for_build=1 ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'publish.sh: unknown argument: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

# --- Preconditions ----------------------------------------------------------

if ! command -v osc >/dev/null 2>&1; then
    printf 'publish.sh: osc(1) not found in PATH.  Install with:  sudo apt install osc\n' >&2
    exit 2
fi

if [ ! -f "$CANONICAL_SERVICE" ]; then
    printf 'publish.sh: %s not found.  Run from the top of the git tree.\n' \
        "$CANONICAL_SERVICE" >&2
    exit 2
fi

if [ "$mode" != check ]; then
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)
    if [ "$branch" != debian/latest ]; then
        printf 'publish.sh: refusing to publish from branch %s (expected debian/latest)\n' \
            "$branch" >&2
        exit 2
    fi
    if ! git diff --quiet || ! git diff --cached --quiet; then
        printf 'publish.sh: working tree is dirty; commit or stash first\n' >&2
        exit 2
    fi
fi

# --- Ensure we have a local OBS checkout ------------------------------------

mkdir -p "$WORKDIR"
if [ ! -d "$WORKDIR/$PROJECT/$PACKAGE/.osc" ]; then
    (cd "$WORKDIR" && osc checkout "$PROJECT" "$PACKAGE")
fi
OBS_CHECKOUT=$WORKDIR/$PROJECT/$PACKAGE

# Pull whatever OBS currently has so the diff below is honest.
(cd "$OBS_CHECKOUT" && osc update >/dev/null)

# --- Drift check ------------------------------------------------------------

obs_service=$OBS_CHECKOUT/_service
if [ -f "$obs_service" ]; then
    if diff -u "$obs_service" "$CANONICAL_SERVICE" >/tmp/publish.diff.$$; then
        drift=0
    else
        drift=1
    fi
else
    # First-ever publish: OBS does not have the file yet.
    drift=1
    printf '(no _service in OBS yet — first publish)\n'
fi

case "$mode" in
    check)
        if [ "$drift" = 0 ]; then
            printf 'OBS is in sync with %s\n' "$CANONICAL_SERVICE"
        else
            printf 'Drift detected between git (canonical) and OBS:\n'
            cat /tmp/publish.diff.$$ 2>/dev/null || true
            printf '\nRun  publish.sh --push   to push git -> OBS,\n'
            printf 'or   publish.sh --pull   to overwrite git from OBS.\n'
        fi
        rm -f /tmp/publish.diff.$$
        exit "$drift"
        ;;

    pull)
        if [ "$drift" = 0 ]; then
            printf 'No drift; nothing to pull.\n'
        else
            cp "$obs_service" "$CANONICAL_SERVICE"
            printf 'Wrote %s from OBS.  Review with `git diff` and commit.\n' \
                "$CANONICAL_SERVICE"
        fi
        rm -f /tmp/publish.diff.$$
        ;;

    push)
        cp "$CANONICAL_SERVICE" "$obs_service"
        (
            cd "$OBS_CHECKOUT"
            # `osc add` is idempotent against tracked files; suppress the
            # "already known" error so re-publishes are quiet.
            osc add _service 2>/dev/null || true
            osc commit -m "Sync _service from git@$(cd - >/dev/null; git rev-parse --short HEAD)"
            # Run the source services so OBS actually fetches the new
            # tarball and re-triggers the build matrix.
            osc service runall
        )
        rm -f /tmp/publish.diff.$$

        if [ "$wait_for_build" = 1 ]; then
            printf '\nWaiting for build matrix (Ctrl-C is safe, builds continue server-side)\n'
            # --csv: machine-readable; --wait: block until each row is final.
            (
                cd "$OBS_CHECKOUT"
                osc results --csv --wait | tee /tmp/publish.results.$$
            )
            if grep -E ',(failed|unresolvable|broken),' /tmp/publish.results.$$ >/dev/null; then
                printf '\nOne or more targets failed:\n' >&2
                grep -E ',(failed|unresolvable|broken),' /tmp/publish.results.$$ >&2
                rm -f /tmp/publish.results.$$
                exit 1
            fi
            printf '\nAll targets succeeded.\n'
            rm -f /tmp/publish.results.$$
        else
            printf '\nUse  publish.sh --push --wait  to block until builds finish,\n'
            printf 'or  (cd %s && osc results)  to poll manually.\n' \
                "$OBS_CHECKOUT"
        fi
        ;;
esac
