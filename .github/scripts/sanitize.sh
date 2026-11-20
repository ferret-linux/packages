#!/usr/bin/env bash
# =============================================================================
#  sanitize.sh <directory>
#  Apply the same RPM filename sanitizer used by --print-nvr probes to the
#  real build output, so probe names and artifact names always agree.
# =============================================================================
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/rpm-name.sh"

DIR="${1:?usage: sanitize.sh <directory>}"
[[ -d "$DIR" ]] || { echo "not a directory: $DIR" >&2; exit 1; }

for rpm in "$DIR"/*.rpm; do
    [[ -f "$rpm" ]] || continue
    base="$(basename "$rpm")"
    clean="$(sanitize_rpm_name "$base")"
    [[ "$base" == "$clean" ]] || mv -- "$rpm" "$DIR/$clean"
done
