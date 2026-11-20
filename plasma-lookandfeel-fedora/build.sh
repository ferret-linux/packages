#!/bin/bash
# =============================================================================
#  Builds an empty replacement RPM for plasma-lookandfeel-fedora.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.github/scripts/nvr.sh"

NAME=plasma-lookandfeel-fedora
RELEASE=1.mink

WORKDIR="/tmp/plasma-lookandfeel-fedora-build"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

if ! (( NVR_MODE )); then
    rm -rf /root
    mkdir -p /root/
fi

# 1 — Install build dependencies
# =============================================================================
info "Installing dependencies..."
if ! (( NVR_MODE )); then
    dnf install -y rpm-build --setopt=install_weak_deps=False -q
fi

# 2 — Get version from repos (strip epoch if present)
# =============================================================================
info "Fetching plasma-lookandfeel-fedora version..."
VERSION=$(dnf repoquery plasma-lookandfeel-fedora 2>/dev/null \
    | grep -v "^Updating\|^Repo\|^$" \
    | sort -V | tail -1 \
    | sed 's/.*-\([0-9][^-]*\)-[^-]*\.[^.]*$/\1/' \
    | sed 's/^[0-9]*://')

[[ -n "$VERSION" ]] || die "Could not determine plasma-lookandfeel-fedora version"
ok "Version: $VERSION"

emit_nvr "$NAME" "$VERSION" "$RELEASE" "noarch"
nvr_done

# 3 — Write spec
# =============================================================================
RPMBUILD="$WORKDIR/rpmbuild"
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/plasma-lookandfeel-fedora.spec" <<SPEC
Name:           plasma-lookandfeel-fedora
Version:        ${VERSION}
Release:        ${RELEASE}%{?dist}
Summary:        Empty replacement for plasma-lookandfeel-fedora
License:        MPL-2
BuildArch:      noarch

Provides:       plasma-lookandfeel-fedora = %{version}-%{release}

Obsoletes:      plasma-lookandfeel-fedora < %{version}

%description
Empty drop-in replacement for plasma-lookandfeel-fedora.
Satisfies all dependencies without installing any Fedora Plasma theming.

%install
# intentionally empty

%files
# intentionally empty

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-${RELEASE}
- Empty replacement for plasma-lookandfeel-fedora (no Fedora theming)
SPEC

# 4 — Build
# =============================================================================
info "Building RPM..."
rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/plasma-lookandfeel-fedora.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "plasma-lookandfeel-fedora-*.rpm" | head -1)
[[ -f "$RPM_FILE" ]] || die "RPM not found after build"

for f in /output/*.rpm; do
    [[ -f "$f" ]] || continue
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

cp "$RPM_FILE" /output/
ok "RPM ready: /output/$(basename "$RPM_FILE")"

rpm -qp --info "/output/$(basename "$RPM_FILE")"