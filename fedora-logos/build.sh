#!/bin/bash
# =============================================================================
#  Builds an empty replacement RPM for fedora-logos.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.github/scripts/nvr.sh"

NAME=fedora-logos
RELEASE=1.mink

WORKDIR="/tmp/fedora-logos-build"
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

# 2 — Get version from the real package in the repos
# =============================================================================
info "Fetching fedora-logos version..."
VERSION=$(dnf info fedora-logos 2>/dev/null \
    | grep -i "^Version" | head -1 | awk '{print $3}')

[[ -n "$VERSION" ]] || die "Could not determine fedora-logos version"
ok "Version: $VERSION"

emit_nvr "$NAME" "$VERSION" "$RELEASE" "noarch"
nvr_done

# 3 — Write spec
# =============================================================================
RPMBUILD="$WORKDIR/rpmbuild"
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/fedora-logos.spec" <<SPEC
Name:           fedora-logos
Version:        ${VERSION}
Release:        ${RELEASE}%{?dist}
Summary:        Empty replacement for fedora-logos
License:        MPL-2
BuildArch:      noarch

# Mirror every Provides from the real package so all dependents are satisfied
Provides:       fedora-logos = %{version}-%{release}
Provides:       gnome-logos = %{version}-%{release}
Provides:       redhat-logos = %{version}-%{release}
Provides:       system-logos = %{version}-%{release}
Provides:       config(fedora-logos) = %{version}-%{release}

# Replace the real package
Obsoletes:      fedora-logos < %{version}

%description
Empty drop-in replacement for fedora-logos.
Satisfies all dependencies without installing any Fedora branding files.

%install
# intentionally empty

%files
# intentionally empty

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-${RELEASE}
- Empty replacement for fedora-logos (no branding)
SPEC

# 4 — Build
# =============================================================================
info "Building RPM..."
rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/fedora-logos.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "fedora-logos-*.rpm" | head -1)
[[ -f "$RPM_FILE" ]] || die "RPM not found after build"

cp "$RPM_FILE" /output/

for f in /output/*.rpm; do
    [[ -f "$f" ]] || continue
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

ok "RPM ready: /output/$(basename "$RPM_FILE")"
rpm -qp --info "/output/$(basename "$RPM_FILE")"