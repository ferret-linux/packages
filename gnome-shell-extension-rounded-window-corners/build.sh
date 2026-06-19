#!/bin/bash
# =============================================================================
#  gnome-shell-extension-rounded-window-corners-reborn/build.sh
#  Source: https://extensions.gnome.org/extension/7048/rounded-window-corners-reborn/
#  (packaged directly from the extensions.gnome.org CDN, NOT from GitHub)
# =============================================================================
set -euo pipefail

EXTENSION_PK=7048   # https://extensions.gnome.org/extension/7048/rounded-window-corners-reborn/
EGO_BASE="https://extensions.gnome.org"

WORKDIR="/tmp/rounded-window-corners-reborn-build"
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
    unzip \
    jq \
    curl \
    --setopt=install_weak_deps=False -q
ok "Dependencies installed"

# 2 — Query extensions.gnome.org for extension metadata + latest version
# =============================================================================
info "Querying extension-info for pk=${EXTENSION_PK}..."
INFO_JSON="$WORKDIR/extension-info.json"
curl -fsSL "${EGO_BASE}/extension-info/?pk=${EXTENSION_PK}" -o "$INFO_JSON" \
    || die "Failed to fetch extension-info"

UUID=$(jq -r '.uuid' "$INFO_JSON")
[[ -n "$UUID" && "$UUID" != "null" ]] || die "Failed to parse UUID from extension-info"
ok "UUID: $UUID"

# The shell_version_map lists, per supported GNOME Shell version, the
# extension "version" (build number) and its download "pk" (version_tag).
# We want the single highest version number across all shell versions —
# that's the latest published release of the extension.
VERSION=$(jq -r '.shell_version_map | to_entries | map(.value.version) | max' "$INFO_JSON")
[[ -n "$VERSION" && "$VERSION" != "null" ]] || die "Failed to determine latest version"
ok "Latest extension version: $VERSION"

DESCRIPTION=$(jq -r '.description // "No description provided."' "$INFO_JSON")
NAME=$(jq -r '.name' "$INFO_JSON")
HOMEPAGE_LINK="${EGO_BASE}/extension/${EXTENSION_PK}/$(jq -r '.link' "$INFO_JSON" | sed -E 's#^/extension/[0-9]+/##; s#/$##')"

# 3 — Download the extension package straight from the e.g.o CDN
# =============================================================================
# Documented, stable URL format:
#   https://extensions.gnome.org/extension-data/{uuid}.v{version}.shell-extension.zip
# Note: upstream source for this extension is written in TypeScript, but
# extensions.gnome.org only accepts/serves plain JS — the zip already
# contains compiled (tsc-transpiled) .js files. No TS toolchain is needed
# here; we're just unpacking an already-built package, same as any other
# extension distributed through this site.
ZIP_URL="${EGO_BASE}/extension-data/${UUID}.v${VERSION}.shell-extension.zip"
ZIP_FILE="$WORKDIR/extension.zip"

info "Downloading ${ZIP_URL} ..."
curl -fsSL "$ZIP_URL" -o "$ZIP_FILE" \
    || die "Failed to download extension package"
ok "Downloaded extension zip"

# 4 — Extract & stage
# =============================================================================
SRC="$WORKDIR/src"
mkdir -p "$SRC"
unzip -q -o "$ZIP_FILE" -d "$SRC"
ok "Extracted extension package"

PARSED_UUID=$(grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' "$SRC/metadata.json" | sed 's/.*"\([^"]*\)"$/\1/')
[[ -n "$PARSED_UUID" ]] || die "Failed to parse UUID from metadata.json"
[[ "$PARSED_UUID" == "$UUID" ]] || info "Note: metadata.json uuid ($PARSED_UUID) differs from e.g.o uuid ($UUID), using metadata.json value"
UUID="$PARSED_UUID"
ok "UUID confirmed: $UUID"

INSTALL_DIR="$STAGING/usr/share/gnome-shell/extensions/$UUID"
mkdir -p "$INSTALL_DIR"

if [[ -d "$SRC/schemas" ]]; then
    info "Compiling GSettings schema..."
    glib-compile-schemas --strict --targetdir="$SRC/schemas/" "$SRC/schemas"
fi

if [[ -d "$SRC/locale" ]]; then
    info "Compiling translations..."
    for po_file in "$SRC"/locale/*/LC_MESSAGES/*.po; do
        [[ -f "$po_file" ]] || continue
        msgfmt "$po_file" -o "${po_file%.po}.mo"
    done
    ok "Translations compiled"
fi

info "Staging extension files..."
shopt -s nullglob
cp -r "$SRC"/*.js "$INSTALL_DIR/" 2>/dev/null || true
for item in locale metadata.json stylesheet.css LICENSE.rst LICENSE LICENSE.md schemas icons resources; do
    [[ -e "$SRC/$item" ]] && cp -r "$SRC/$item" "$INSTALL_DIR/"
done
shopt -u nullglob
ok "Build complete"

# — Generate exact file list from staging
FILES_LIST=$(find "$STAGING" -not -type d | sed "s|^$STAGING||")

# 5 — Write spec
# =============================================================================
info "Writing spec..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/gnome-shell-extension-rounded-window-corners-reborn.spec" <<SPEC
Name:           gnome-shell-extension-rounded-window-corners-reborn
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        ${NAME}
License:        GPL-3.0-or-later
BuildArch:      noarch
URL:            ${HOMEPAGE_LINK}

Requires:       gnome-shell

%description
${DESCRIPTION}

%install
cp -a "${STAGING}/." "%{buildroot}/"

%files
${FILES_LIST}

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-1
- Automated build from extensions.gnome.org (pk=${EXTENSION_PK}, version=${VERSION})
SPEC

# 6 — Build RPM
# =============================================================================
info "Building RPM..."
rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/gnome-shell-extension-rounded-window-corners-reborn.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "gnome-shell-extension-rounded-window-corners-reborn-*.rpm" | head -1)
[[ -f "$RPM_FILE" ]] || die "RPM not found after build"

mkdir -p /output
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