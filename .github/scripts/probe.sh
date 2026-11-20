#!/usr/bin/env bash
# =============================================================================
#  probe.sh — ask every build.sh for the exact RPMs it would produce
#
#  Runs on the host. Each package's build.sh is invoked with --print-nvr inside
#  a FRESH build container — the same image and the same clean environment the
#  real build job uses. This matters: build scripts enable repos and install
#  packages, so sharing one container across packages would leak state.
#
#  --print-nvr performs only upstream version detection and exits before
#  compiling/packaging. Probe and build therefore share one code path, with no
#  second version-detection implementation that could drift out of sync.
#
#  Output TSV (one line per package):
#      <package>\t<expected-rpm-1>\t<expected-rpm-2>...
# =============================================================================
set -euo pipefail

OUT="${1:?usage: probe.sh <results.tsv> [pkg ...]}"
shift

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
IMAGE="${BUILD_IMAGE:-quay.io/fedora/fedora-bootc:latest}"
: > "$OUT"

for script in "$REPO"/*/build.sh; do
    [[ -f "$script" ]] || continue
    pkg="$(basename "$(dirname "$script")")"

    if (($# > 0)); then
        match=0
        for wanted in "$@"; do
            [[ "$pkg" == "$wanted" ]] && match=1 && break
        done
        (( match )) || continue
    fi

    tmp="$(mktemp -d)"
    mkdir -p "$tmp/output"

    docker run --rm \
        -e GITHUB_TOKEN \
        -e NVR_OUTFILE=/probe/nvr.txt \
        -v "$REPO:/repo:ro" \
        -v "$tmp:/probe" \
        -v "$tmp/output:/output" \
        "$IMAGE" \
        bash "/repo/$pkg/build.sh" --print-nvr >/dev/null

    [[ -s "$tmp/nvr.txt" ]] || {
        echo "probe produced no expected RPMs for $pkg" >&2
        rm -rf "$tmp"
        exit 1
    }

    names=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && names+=("$line")
    done < "$tmp/nvr.txt"
    rm -rf "$tmp"

    printf '%s' "$pkg" >> "$OUT"
    for name in "${names[@]}"; do
        printf '\t%s' "$name" >> "$OUT"
    done
    printf '\n' >> "$OUT"

    printf '[%s] %s\n' "$pkg" "${names[*]}"
done

echo "Probed $(wc -l < "$OUT") packages"
