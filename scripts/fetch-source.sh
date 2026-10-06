#!/bin/sh
# Fetch the pinned FreeBSD source into build/freebsd-src and apply patches/.
#
# The checkout is a single-commit (shallow) clone of FREEBSD_COMMIT. Its tree
# must match FREEBSD_TREE before the local patches are applied with git am,
# and the patched tree is recorded in build/freebsd-src.tree. Running this
# again on an existing checkout only verifies it.
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$here/config/freebsd.env"
src=${FREEBSD_SRC:-$here/build/freebsd-src}
die() { echo "fetch-source: $*" >&2; exit 1; }

patch_list() {
    grep -Ev '^[[:space:]]*(#|$)' "$here/patches/series"
}

# Every listed patch must match patches/SHA256SUMS.
if [ -s "$here/patches/SHA256SUMS" ]; then
    (cd "$here/patches" && sha256sum --quiet -c SHA256SUMS) || die 'patches/SHA256SUMS mismatch'
fi
for p in $(patch_list); do
    grep -q "^[0-9a-f]\{64\}  $p\$" "$here/patches/SHA256SUMS" ||
        die "patches/$p is not listed in patches/SHA256SUMS"
done

stamp=$src/.freebsd-img-maker
want="$FREEBSD_COMMIT $(cat "$here/patches/series" "$here/patches/SHA256SUMS" | sha256sum | cut -d' ' -f1)"
if [ -d "$src/.git" ]; then
    [ "$(cat "$stamp" 2>/dev/null)" = "$want" ] ||
        die "$src exists but was prepared from other inputs; remove it to refetch"
    [ -z "$(git -C "$src" status --porcelain --untracked-files=no)" ] || die "$src has local changes"
    [ "$(git -C "$src" rev-parse 'HEAD^{tree}')" = "$(cat "$src.tree")" ] || die "$src moved from its recorded tree"
    echo "FreeBSD source ready: $src ($(cat "$src.tree"))"
    exit 0
fi
[ ! -e "$src" ] || die "$src exists and is not a git checkout"

mkdir -p "$(dirname -- "$src")"
git init -q "$src"
git -C "$src" remote add origin "$FREEBSD_REPO"
git -C "$src" fetch -q --depth 1 origin "$FREEBSD_COMMIT"
git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD
[ "$(git -C "$src" rev-parse HEAD)" = "$FREEBSD_COMMIT" ] || die 'fetched the wrong commit'
[ "$(git -C "$src" rev-parse 'HEAD^{tree}')" = "$FREEBSD_TREE" ] || die 'source tree does not match FREEBSD_TREE'

# Fixed committer identity and dates, so the patched commits are reproducible.
for p in $(patch_list); do
    GIT_COMMITTER_NAME=freebsd-img-maker GIT_COMMITTER_EMAIL=freebsd-img-maker@localhost \
        GIT_COMMITTER_DATE='1970-01-01T00:00:00Z' \
        git -C "$src" -c user.name=freebsd-img-maker -c user.email=freebsd-img-maker@localhost \
        am -q --committer-date-is-author-date "$here/patches/$p" || die "patch $p does not apply"
done
git -C "$src" rev-parse 'HEAD^{tree}' > "$src.tree"
printf '%s\n' "$want" > "$stamp"
echo "FreeBSD source ready: $src ($(cat "$src.tree"))"
