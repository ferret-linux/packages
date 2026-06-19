#!/bin/bash
# =============================================================================
#  gnome-shell-extension-clipboard-indicator/build.sh
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/clipboard-indicator-build"
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
    glib2-devel \
    gettext \
    rpm-build \
    git \
    --setopt=install_weak_deps=False -q
ok "Dependencies installed"

# 2 — Detect latest stable tag
# =============================================================================
info "Detecting latest stable tag..."
TAG=$(git ls-remote --tags https://github.com/Tudmotu/gnome-shell-extension-clipboard-indicator.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -E '^v[0-9]+$' \
    | sed 's/^v//' \
    | sort -n \
    | tail -1 \
    | sed 's/^/v/')

[[ -n "$TAG" ]] || die "Failed to detect latest tag"
VERSION=${TAG#v}
ok "Tag: $TAG"
ok "Version: $VERSION"

# 3 — Clone source
# =============================================================================
info "Cloning clipboard-indicator at $TAG..."
git clone --depth 1 --branch "$TAG" \
    https://github.com/Tudmotu/gnome-shell-extension-clipboard-indicator.git \
    "$WORKDIR/src"
ok "Source cloned"

# 4 — Resolve UUID and build
# =============================================================================
SRC="$WORKDIR/src"
UUID=$(grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' "$SRC/metadata.json" | sed 's/.*"\([^"]*\)"$/\1/')
[[ -n "$UUID" ]] || die "Failed to parse UUID from metadata.json"
ok "UUID: $UUID"

INSTALL_DIR="$STAGING/usr/share/gnome-shell/extensions/$UUID"
mkdir -p "$INSTALL_DIR"

info "Compiling GSettings schema..."
glib-compile-schemas --strict --targetdir="$SRC/schemas/" "$SRC/schemas"

info "Compiling translations..."
for po_file in "$SRC"/locale/*/LC_MESSAGES/*.po; do
    [[ -f "$po_file" ]] || continue
    msgfmt "$po_file" -o "${po_file%.po}.mo"
done
ok "Translations compiled"

info "Staging extension files..."
cp -r \
    "$SRC"/*.js \
    "$SRC/locale" \
    "$SRC/metadata.json" \
    "$SRC/stylesheet.css" \
    "$SRC/LICENSE.rst" \
    "$SRC/schemas" \
    "$INSTALL_DIR/"
ok "Build complete"

# — Generate exact file list from staging
FILES_LIST=$(find "$STAGING" -not -type d | sed "s|^$STAGING||")

# 5 — Write spec
# =============================================================================
info "Writing spec..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/gnome-shell-extension-clipboard-indicator.spec" <<SPEC
Name:           gnome-shell-extension-clipboard-indicator
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        The most popular clipboard manager for GNOME
License:        MIT
BuildArch:      noarch
URL:            https://github.com/Tudmotu/gnome-shell-extension-clipboard-indicator

Requires:       gnome-shell

%description
Clipboard Indicator is a clipboard manager extension for GNOME Shell with
over 1M downloads. It keeps a history of copied text and lets you quickly
access and paste from it.

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
    -bb "$RPMBUILD/SPECS/gnome-shell-extension-clipboard-indicator.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "gnome-shell-extension-clipboard-indicator-*.rpm" | head -1)
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