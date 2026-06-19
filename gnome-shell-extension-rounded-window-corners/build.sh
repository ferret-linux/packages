#!/bin/bash
# =============================================================================
#  gnome-shell-extension-rounded-window-corners/build.sh
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/rwc-build"
STAGING="$WORKDIR/staging"
RPMBUILD="$WORKDIR/rpmbuild"
UUID="rounded-window-corners@fxgn"
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
    nodejs \
    npm \
    glib2 \
    glib2-devel \
    gettext \
    rpm-build \
    git \
    --setopt=install_weak_deps=False -q
ok "Dependencies installed"

# 2 — Detect latest stable tag
# =============================================================================
info "Detecting latest stable tag..."
VERSION=$(git ls-remote --tags https://github.com/flexagoon/rounded-window-corners.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -v -- '-' \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's/^v//' \
    | sort -V \
    | tail -1)

[[ -n "$VERSION" ]] || die "Failed to detect latest stable version"
ok "Version: $VERSION"

TAG="v${VERSION}"
ok "Tag: $TAG"

# 3 — Clone source
# =============================================================================
info "Cloning rounded-window-corners at $TAG..."
git clone --depth 1 --branch "$TAG" \
    https://github.com/flexagoon/rounded-window-corners.git \
    "$WORKDIR/src"
ok "Source cloned"

# 4 — Build
# =============================================================================
BUILDDIR="$WORKDIR/build"
mkdir -p "$BUILDDIR"

info "Installing npm dependencies..."
( cd "$WORKDIR/src" && npm install --save-dev )

info "Compiling TypeScript..."
( cd "$WORKDIR/src" && npx tsc --outDir "$BUILDDIR" )

info "Copying non-TS files..."
cp -r "$WORKDIR/src/resources/"* "$BUILDDIR/"
find "$WORKDIR/src/src" -type f ! -name "*.ts" | while read -r file; do
    rel="${file#$WORKDIR/src/src/}"
    dir="$BUILDDIR/$(dirname "$rel")"
    mkdir -p "$dir"
    cp "$file" "$dir/"
done

info "Compiling translations..."
for po_file in "$WORKDIR/src/po/"*.po; do
    [[ -f "$po_file" ]] || continue
    locale=$(basename "$po_file" .po)
    mkdir -p "$BUILDDIR/locale/$locale/LC_MESSAGES"
    msgfmt -o "$BUILDDIR/locale/$locale/LC_MESSAGES/$UUID.mo" "$po_file"
    ok "Compiled translation: $locale"
done

info "Compiling GSettings schemas..."
glib-compile-schemas "$BUILDDIR/schemas/"
ok "Build complete"

# 5 — Stage
# =============================================================================
INSTALL_DIR="$STAGING/usr/share/gnome-shell/extensions/$UUID"
mkdir -p "$INSTALL_DIR"
cp -r "$BUILDDIR/"* "$INSTALL_DIR/"

# — Generate exact file list from staging
FILES_LIST=$(find "$STAGING" -not -type d | sed "s|^$STAGING||")

# 6 — Write spec
# =============================================================================
info "Writing spec..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/gnome-shell-extension-rounded-window-corners.spec" <<SPEC
Name:           gnome-shell-extension-rounded-window-corners
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Add rounded corners to all windows
License:        GPL-3.0-or-later
BuildArch:      noarch
URL:            https://github.com/flexagoon/rounded-window-corners

Requires:       gnome-shell

%description
Rounded Window Corners Reborn is a GNOME Shell extension that adds rounded
corners to all windows. Fork of the now unmaintained Rounded Window Corners
extension.

%install
cp -a "${STAGING}/." "%{buildroot}/"

%files
${FILES_LIST}

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-1
- Automated build from tag ${TAG}
SPEC

# 7 — Build RPM
# =============================================================================
info "Building RPM..."
rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/gnome-shell-extension-rounded-window-corners.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "gnome-shell-extension-rounded-window-corners-*.rpm" | head -1)
[[ -f "$RPM_FILE" ]] || die "RPM not found after build"

cp "$RPM_FILE" /output/

# 8 — Sanitize filename & summarize
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