#!/usr/bin/env bash
#
# Reproducibly build the custom rclone binary used by protonsync.
#
# It clones three upstream rclone-org repositories at the exact commits listed
# in pinned-commits.txt, applies the patches in patches/, and compiles a single
# static-ish rclone binary that adds:
#   * Proton Drive "Shared with me" support as a remote root
#   * a new `protonwatch` command that streams Proton Drive change events
#
# All three upstream projects are MIT licensed; the patches here are likewise
# released under MIT (see ../LICENSE and ../NOTICE).
#
# Requirements: git, and Go >= 1.25 (the upstream rclone go.mod requires it).
# Network access is needed for the clones and the Go module downloads.
#
# Usage:
#   ./build.sh                 # builds ./protonsync-rclone
#   BUILD_DIR=/tmp/x ./build.sh # use a custom scratch directory
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES="$HERE/patches"
WORK="${BUILD_DIR:-$HERE/build}"
OUT="$HERE/protonsync-rclone"

if ! command -v git >/dev/null 2>&1; then
    echo "git is required." >&2
    exit 1
fi
if ! command -v go >/dev/null 2>&1; then
    echo "Go (>= 1.25) is required." >&2
    exit 1
fi

go_minor="$(go version | sed -nE 's/.*go1\.([0-9]+).*/\1/p')"
if [[ -z "$go_minor" || "$go_minor" -lt 25 ]]; then
    echo "Warning: upstream rclone requires Go >= 1.25; you have $(go version)." >&2
    echo "The build may fail. Install a newer Go toolchain if it does." >&2
fi

mkdir -p "$WORK"

prepare() {
    # name url commit
    local name="$1" url="$2" commit="$3"
    local dir="$WORK/$name"
    if [[ ! -d "$dir/.git" ]]; then
        echo ">> Cloning $name"
        git clone --quiet "$url" "$dir"
    fi
    echo ">> Checking out $name @ $commit"
    git -C "$dir" fetch --quiet --all
    git -C "$dir" checkout --quiet "$commit"
    git -C "$dir" reset --hard --quiet "$commit"
    git -C "$dir" clean -fdq
}

apply_fork() {
    # dir patchdir
    local dir="$1" pd="$2"
    if [[ -s "$pd/tracked.patch" ]]; then
        echo ">> Applying tracked.patch to $(basename "$dir")"
        git -C "$dir" apply --whitespace=nowarn "$pd/tracked.patch"
    fi
    if [[ -d "$pd/new" ]] && find "$pd/new" -type f -print -quit | grep -q .; then
        echo ">> Adding new files to $(basename "$dir")"
        cp -a "$pd/new/." "$dir/"
    fi
}

# Read the pinned commits and prepare each repository.
while read -r name url commit; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    prepare "$name" "$url" "$commit"
done < <(grep -vE '^\s*#|^\s*$' "$HERE/pinned-commits.txt")

apply_fork "$WORK/rclone" "$PATCHES/rclone"
apply_fork "$WORK/proton-api-bridge" "$PATCHES/proton-api-bridge"
apply_fork "$WORK/go-proton-api" "$PATCHES/go-proton-api"

echo ">> Building rclone (this can take a few minutes)"
cd "$WORK/rclone"
go build -trimpath -ldflags "-s -w" -o "$OUT" .

echo
echo "Build complete: $OUT"
"$OUT" version | head -n 1
echo "Verify the custom command is present:"
"$OUT" protonwatch --help >/dev/null && echo "  protonwatch: OK"
