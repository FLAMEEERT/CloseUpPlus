#!/bin/bash
# Compute the version for a CI build from git tags.
#
# Local builds are always 0.0.0-development (project.yml); real versions exist
# only in CI, derived from tags by this script. Requires the full tag list
# (checkout with fetch-depth: 0 + fetch-tags: true).
#
# Usage:
#   compute_version.sh release
#     env: EXPECTED_VERSION  optional explicit version (1.2.3 or 1.2.3-rc.1;
#                            leading "v" accepted). Empty -> auto-bump.
#                            A stable explicit version must be greater than
#                            the latest stable tag (no backfills: a newer-
#                            created release would steal "Latest" and the
#                            date-stamped build number would top the appcast).
#          VERSION_BUMP      segment to bump when EXPECTED_VERSION is empty:
#                            patch | minor | major (default patch).
#   compute_version.sh beta
#     Next patch of the latest stable tag + "-beta.N" (stable 1.2.3 ->
#     1.2.4-beta.N), so a nightly always version-sorts above the stable it
#     was built after. N continues from the highest existing
#     vX.Y.Z-beta.* tag for that base (the base moves whenever a new
#     stable ships, resetting N). Errors when no stable tag exists yet —
#     dispatch the first stable release to set the beta baseline.
#
# Output (appended to $GITHUB_OUTPUT when set, always echoed):
#   version=1.2.3[-pre]    display version (MARKETING_VERSION)
#   tag=v1.2.3[-pre]       git tag / GitHub Release tag
#   prerelease=true|false  GitHub Release pre-release flag (never "Latest")
set -euo pipefail

mode="${1:?usage: compute_version.sh release|beta}"

# Numeric segments reject leading zeros ("01" would later be read as octal by
# bash arithmetic); pre-release identifiers are dot-separated [0-9A-Za-z-]
# runs, so no leading/trailing/consecutive dots can reach the tag name.
NUM='(0|[1-9][0-9]*)'
VERSION_RE="^${NUM}\.${NUM}\.${NUM}(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"

# Newest tag that is exactly vX.Y.Z (pre-release tags are ignored).
latest_stable() {
    git tag -l 'v*' --sort=-v:refname \
        | grep -E "^v${NUM}\.${NUM}\.${NUM}$" \
        | head -n1 \
        || true
}

case "$mode" in
release)
    expected="${EXPECTED_VERSION:-}"
    bump="${VERSION_BUMP:-patch}"
    if [ -n "$expected" ]; then
        version="${expected#v}"
        if ! [[ "$version" =~ $VERSION_RE ]]; then
            echo "error: version must be X.Y.Z or X.Y.Z-pre (got '$expected')" >&2
            exit 1
        fi
        # A stable explicit version may only move forward.
        if [[ "$version" != *-* ]]; then
            latest="$(latest_stable)"
            latest="${latest#v}"
            if [ -n "$latest" ] && [ "$version" != "$(printf '%s\n%s\n' "$latest" "$version" | sort -V | tail -n1)" ]; then
                echo "error: $version is not newer than the latest stable $latest (backfill releases are not supported)" >&2
                exit 1
            fi
        fi
    else
        base_tag="$(latest_stable)"
        if [ -n "$base_tag" ] && [ "$(git rev-parse "${base_tag}^{commit}")" = "$(git rev-parse HEAD)" ]; then
            # A failed publish creates its lightweight tag together with the
            # draft. Reuse it on a same-commit re-dispatch so the draft can be
            # completed instead of silently skipping to the next version.
            version="${base_tag#v}"
        else
            base="${base_tag#v}"
            base="${base:-0.0.0}"
            IFS=. read -r major minor patch <<<"$base"
            case "$bump" in
            major) version="$((major + 1)).0.0" ;;
            minor) version="${major}.$((minor + 1)).0" ;;
            patch) version="${major}.${minor}.$((patch + 1))" ;;
            *)
                echo "error: unsupported bump '$bump'" >&2
                exit 1
                ;;
            esac
        fi
    fi
    ;;
beta)
    base="$(latest_stable)"
    base="${base#v}"
    if [ -z "$base" ]; then
        echo "error: no stable tag exists yet — dispatch the first stable release (Actions -> Release) to set the beta baseline" >&2
        exit 1
    fi
    # The beta base is the *next patch* of the latest stable, so a nightly
    # always version-sorts above the stable it was built after (Sparkle
    # orders by the date-stamped build number regardless; this keeps the
    # marketing version telling the same story). The base can never collide
    # with an existing stable tag: if vX.Y.(Z+1) existed, it — not vX.Y.Z —
    # would be the latest stable.
    IFS=. read -r major minor patch <<<"$base"
    base="${major}.${minor}.$((patch + 1))"
    max=0
    for t in $(git tag -l "v${base}-beta.*"); do
        n="${t#v"${base}"-beta.}"
        [[ "$n" =~ ^(0|[1-9][0-9]*)$ ]] || continue
        if ((n > max)); then max="$n"; fi
    done
    latest_beta="v${base}-beta.${max}"
    if ((max > 0)) && [ "$(git rev-parse "${latest_beta}^{commit}")" = "$(git rev-parse HEAD)" ]; then
        version="${latest_beta#v}"
    else
        version="${base}-beta.$((max + 1))"
    fi
    ;;
*)
    echo "error: unknown mode '$mode' (expected release|beta)" >&2
    exit 1
    ;;
esac

tag="v${version}"
git check-ref-format "refs/tags/${tag}" || {
    echo "error: '${tag}' is not a valid tag name" >&2
    exit 1
}
if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    # Allow re-dispatching the same version for the same commit: a publish run
    # that failed after its tag was created can be retried verbatim, and the
    # release step updates the existing tag/release in place.
    if [ "$(git rev-parse "refs/tags/${tag}^{commit}")" = "$(git rev-parse HEAD)" ]; then
        echo "warning: tag ${tag} already exists and points at HEAD — re-publishing it" >&2
    else
        echo "error: tag ${tag} already exists (and points at a different commit)" >&2
        exit 1
    fi
fi

if [[ "$version" == *-* ]]; then prerelease=true; else prerelease=false; fi

out="version=${version}
tag=${tag}
prerelease=${prerelease}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$out" >>"$GITHUB_OUTPUT"
fi
echo "$out"
