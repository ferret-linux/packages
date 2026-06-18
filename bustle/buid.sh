#!/bin/bash
# =============================================================================
#  bustle/build.sh
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/bustle-build"
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
    rust cargo \
    meson \
    rpm-build \
    gettext \
    glib2-devel \
    gtk4-devel \
    libadwaita-devel \
    git \
    --setopt=install_weak_deps=False -q
ok "Dependencies installed"

# 2 — Detect latest stable tag
# =============================================================================
info "Detecting latest stable tag..."
# Uses the GitLab releases API; project ID 26802 is org.freedesktop.Bustle
TAG=$(curl -sf "https://gitlab.gnome.org/api/v4/projects/26802/releases/?per_page=1" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['tag_name'])")

[[ -n "$TAG" ]] || die "Failed to detect latest tag"

VERSION=$(echo "$TAG" | sed 's/^v//')
[[ -n "$VERSION" ]] || die "Failed to strip version from tag $TAG"

ok "Tag: $TAG"
ok "Version: $VERSION"

# 3 — Clone source
# =============================================================================
info "Cloning bustle at $TAG..."
git clone --depth 1 --branch "$TAG" \
    https://gitlab.gnome.org/World/bustle.git \
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

cat > "$RPMBUILD/SPECS/bustle.spec" <<SPEC
Name:           bustle
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        D-Bus activity viewer and analyser
License:        LGPL-2.1-or-later
BuildArch:      x86_64
URL:            https://apps.gnome.org/Bustle/

Requires:       gtk4
Requires:       libadwaita

%description
Bustle draws sequence diagrams of D-Bus activity. It shows signal emissions,
method calls and their corresponding returns, with timestamps for each event
and the duration of each method call.

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
    -bb "$RPMBUILD/SPECS/bustle.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "bustle-*.rpm" | head -1)
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