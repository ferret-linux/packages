#!/usr/bin/env bash
# =============================================================================
#  nvr.sh — --print-nvr support for every package build.sh
#
#  Sourced by build.sh. In normal mode every function here is a no-op.
#  When --print-nvr is passed, expected RPM asset filenames are written to
#  $NVR_OUTFILE (one per line) and the script exits before doing any build.
#
#  This is the single source of truth for skip/prune decisions: the exact same
#  build script computes both the expected names and the actual RPMs.
# =============================================================================

if [[ -f "$(dirname "${BASH_SOURCE[0]}")/rpm-name.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/rpm-name.sh"
fi

NVR_MODE=0
for _nvr_arg in "$@"; do
    [[ "$_nvr_arg" == "--print-nvr" ]] && NVR_MODE=1
done
unset _nvr_arg

# Dist and native arch come from the actual build image, never hardcoded.
NVR_DIST="${NVR_DIST:-$(rpm --eval '%{dist}' 2>/dev/null || true)}"
NVR_ARCH="${NVR_ARCH:-$(rpm --eval '%{_arch}' 2>/dev/null || echo x86_64)}"

_nvr_emit() {
    (( NVR_MODE )) || return 0
    [[ -n "${NVR_OUTFILE:-}" ]] || return 0
    printf '%s\n' "$(sanitize_rpm_name "$1")" >> "$NVR_OUTFILE"
}

# emit_nvr <name> <version> <release-without-dist> <arch>
# Emits the exact asset filename a build of this spec would produce.
emit_nvr() {
    local name="$1" ver="$2" rel="$3" arch="$4"
    _nvr_emit "${name}-${ver}-${rel}${NVR_DIST}.${arch}.rpm"
}

# emit_raw_nvr <exact-filename>
# Emits an exact asset filename (already includes version, release, arch).
emit_raw_nvr() {
    _nvr_emit "$1"
}

# emit_dnf_urls <package>...
# NVR-only: resolve packages through dnf and emit their filenames from the
# download URLs, without transferring any RPM bytes. Uses the exact same dnf
# resolution as the real build — just skips the download itself.
emit_dnf_urls() {
    (( NVR_MODE )) || return 0
    local url name
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        name="${url##*/}"
        name="${name%%\?*}"
        _nvr_emit "$name"
    done < <(dnf download --url --arch x86_64 --arch noarch "$@" 2>/dev/null)
}

# emit_dir_nvrs <directory>
# Emits the sanitized basenames of every RPM in a directory (republished RPMs).
emit_dir_nvrs() {
    local dir="$1"
    (( NVR_MODE )) || return 0
    [[ -d "$dir" ]] || return 0
    local f
    while IFS= read -r f; do
        _nvr_emit "$f"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.rpm' -printf '%f\n' | sort)
}

# Call after all emits for a package.
nvr_done() {
    if (( NVR_MODE )); then
        exit 0
    fi
    return 0
}
