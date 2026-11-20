#!/usr/bin/env bash
# =============================================================================
#  probe.sh — ask every build.sh for the exact RPMs it would produce
#
#  Runs INSIDE quay.io/fedora/fedora-bootc:latest. Each package's build.sh is
#  invoked with --print-nvr, which performs only its upstream version detection
#  and then exits before compiling/packaging. That keeps probe and build on the
#  exact same code path — there is no second version-detection implementation
#  that could drift out of sync.
#
#  Output TSV (one line per package):
#      <package>\t<expected-rpm-1>\t<expected-rpm-2>...
# =============================================================================
set -euo pipefail

OUT="${1:?usage: probe.sh <results.tsv> [pkg ...]}"
REPO="${REPO:-/repo}"
shift
: > "$OUT"
mkdir -p /output

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

    # /output is throwaway for probes, but each package must start clean so a
    # directory-listing probe (e.g. docker-ce) only sees its own downloads.
    rm -f /output/*.rpm

    expected_file="$(mktemp)"
    NVR_OUTFILE="$expected_file" bash "$script" --print-nvr >/dev/null
    [[ -s "$expected_file" ]] || {
        echo "probe produced no expected RPMs for $pkg" >&2
        rm -f "$expected_file"
        exit 1
    }

    names=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && names+=("$line")
    done < "$expected_file"
    rm -f "$expected_file"

    printf '%s' "$pkg" >> "$OUT"
    for name in "${names[@]}"; do
        printf '\t%s' "$name" >> "$OUT"
    done
    printf '\n' >> "$OUT"

    printf '[%s] %s\n' "$pkg" "${names[*]}"
done

echo "Probed $(wc -l < "$OUT") packages"
