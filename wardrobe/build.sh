#!/bin/bash
# =============================================================================
#  wardrobe/build.sh
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/wardrobe-build"
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
    meson \
    rpm-build \
    gettext \
    git \
    glib2-devel \
    python3-gobject \
    desktop-file-utils \
    libappstream-glib \
    --setopt=install_weak_deps=False -q
ok "Dependencies installed"

# 2 — Detect latest stable tag
# =============================================================================
info "Detecting latest stable tag..."
VERSION=$(git ls-remote --tags https://github.com/SwordPuffin/Wardrobe.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -v -- '-' \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's/^v//' \
    | sort -V \
    | tail -1)

[[ -n "$VERSION" ]] || die "Failed to detect latest stable version"
ok "Version: $VERSION"

TAG=$(git ls-remote --tags https://github.com/SwordPuffin/Wardrobe.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -v -- '-' \
    | grep -E "^v?${VERSION}$" \
    | head -1)

[[ -n "$TAG" ]] || die "Could not resolve tag for version $VERSION"
ok "Tag: $TAG"

# 3 — Clone source
# =============================================================================
info "Cloning Wardrobe at $TAG..."
git clone --depth 1 --branch "$TAG" \
    https://github.com/SwordPuffin/Wardrobe.git \
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

# — Generate exact file list from staging
FILES_LIST=$(find "$STAGING" -not -type d | sed "s|^$STAGING||")

# 5 — Write spec
# =============================================================================
info "Writing spec..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/wardrobe.spec" <<SPEC
Name:           wardrobe
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Prettify your desktop effortlessly
License:        GPL-3.0-or-later
BuildArch:      x86_64
URL:            https://github.com/SwordPuffin/Wardrobe

Requires:       gtk4
Requires:       libadwaita
Requires:       python3-gobject
Requires:       gnome-autoar
Requires:       libportal-gtk4
Requires:       libsoup3
Requires:       xdg-utils

%description
Wardrobe is a GNOME Shell theme manager that lets you browse, install, and
manage shell themes, icons, cursors, and wallpapers.

%install
cp -a "${STAGING}/." "%{buildroot}/"

%files
${FILES_LIST}

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-1
- Automated build from tag ${TAG}
SPEC

# 6 — Build RPM
# =============================================================================
info "Building RPM..."
rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/wardrobe.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "wardrobe-*.rpm" | head -1)
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