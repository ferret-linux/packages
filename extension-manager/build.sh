#!/bin/bash
# =============================================================================
#  extension-manager/build.sh
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/extension-manager-build"
STAGING="$WORKDIR/staging"
RPMBUILD="$WORKDIR/rpmbuild"
mkdir -p "$WORKDIR"

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

rm -rf /root
mkdir -p /root/

# 1 — Install build dependencies
# =============================================================================
info "Installing build dependencies..."
dnf install -y \
    gcc \
    meson \
    rpm-build \
    gettext \
    git \
    blueprint-compiler \
    gtk4-devel \
    libadwaita-devel \
    json-glib-devel \
    libsoup3-devel \
    libxml2-devel \
    glib2-devel \
    --setopt=install_weak_deps=False -q
ok "Dependencies installed"

# 2 — Detect latest stable tag
# =============================================================================
info "Detecting latest stable tag..."
TAG=$(git ls-remote --tags https://github.com/mjakeman/extension-manager.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | sort -V \
    | tail -1)

[[ -n "$TAG" ]] || die "Failed to detect latest tag"

VERSION=$(echo "$TAG" | sed 's/^v//')
[[ -n "$VERSION" ]] || die "Failed to strip version from tag $TAG"

ok "Tag: $TAG"
ok "Version: $VERSION"

# 3 — Clone source
# =============================================================================
info "Cloning extension-manager at $TAG..."
git clone --depth 1 --branch "$TAG" \
    https://github.com/mjakeman/extension-manager.git \
    "$WORKDIR/src"
ok "Source cloned"

# 4 — Build
# =============================================================================
info "Configuring with meson..."
meson setup "$WORKDIR/build" "$WORKDIR/src" \
    --prefix=/usr \
    --buildtype=release

info "Compiling..."
meson compile -C "$WORKDIR/build"

info "Installing to staging..."
mkdir -p "$STAGING"
DESTDIR="$STAGING" meson install -C "$WORKDIR/build"
ok "Build complete"

# 5 — Write spec
# =============================================================================
info "Writing spec..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/extension-manager.spec" <<SPEC
Name:           extension-manager
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        A native tool for browsing and installing GNOME Shell Extensions
License:        GPL-3.0-only
BuildArch:      x86_64
URL:            https://github.com/mjakeman/extension-manager

Requires:       gtk4
Requires:       libadwaita
Requires:       json-glib
Requires:       libsoup3
Requires:       libxml2

%description
A native tool for browsing, installing, and managing GNOME Shell Extensions.
Written with GTK 4 and libadwaita.

%install
cp -a "${STAGING}/." "%{buildroot}/"

%files
/usr/*

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-1
- Automated build from tag ${TAG}
SPEC

# 6 — Build RPM
# =============================================================================
info "Building RPM..."
rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/extension-manager.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "extension-manager-*.rpm" | head -1)
[[ -f "$RPM_FILE" ]] || die "RPM not found after build"

cp "$RPM_FILE" /output/

# 7 — Sanitize filename & summarize
# =============================================================================
for f in /output/*.rpm; do
    [[ -f "$f" ]] || continue
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

ok "RPM ready: /output/$(basename "$RPM_FILE")"
rpm -qp --info "/output/$(basename "$RPM_FILE")"
rpm -qp --list "/output/$(basename "$RPM_FILE")"