#!/bin/bash
# =============================================================================
#  gnome-shell-extension-all-in-one-clipboard/build.sh
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/aio-clipboard-build"
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
    jq \
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
TAG=$(git ls-remote --tags https://github.com/NiffirgkcaJ/all-in-one-clipboard.git \
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
info "Cloning all-in-one-clipboard at $TAG..."
git clone --depth 1 --branch "$TAG" \
    https://github.com/NiffirgkcaJ/all-in-one-clipboard.git \
    "$WORKDIR/src"
ok "Source cloned"

# 4 — Resolve UUID and build
# =============================================================================
EXT_SRC="$WORKDIR/src/gnome-extensions/extension"
UUID=$(jq -r '.uuid' "$EXT_SRC/metadata.json")
[[ -n "$UUID" && "$UUID" != "null" ]] || die "Failed to parse UUID from metadata.json"
ok "UUID: $UUID"

INSTALL_DIR="$STAGING/usr/share/gnome-shell/extensions/$UUID"

info "Staging extension source..."
mkdir -p "$INSTALL_DIR"
cp -r "$EXT_SRC"/* "$INSTALL_DIR/"

if [[ -d "$INSTALL_DIR/schemas" ]]; then
    info "Compiling GSettings schema..."
    glib-compile-schemas "$INSTALL_DIR/schemas/"
fi

info "Compiling GResource bundle..."
( cd "$INSTALL_DIR" && glib-compile-resources --target=resources.gresource all-in-one-clipboard.gresource.xml )

info "Cleaning up source assets..."
rm -rf "$INSTALL_DIR/assets"
rm -f "$INSTALL_DIR/all-in-one-clipboard.gresource.xml"

info "Compiling translations..."
TRANSLATION_DIR="$WORKDIR/src/gnome-extensions/translation"
if [[ -d "$TRANSLATION_DIR" ]]; then
    for po_file in "$TRANSLATION_DIR"/*.po; do
        [[ -f "$po_file" ]] || continue
        base=$(basename "$po_file" .po)
        [[ "$base" == *"@"* ]] || continue

        lang_code=${base#*@}
        domain=${base%@*}

        mkdir -p "$INSTALL_DIR/locale/$lang_code/LC_MESSAGES"
        msgfmt --output-file="$INSTALL_DIR/locale/$lang_code/LC_MESSAGES/$domain.mo" "$po_file"
        ok "Compiled translation: $domain ($lang_code)"
    done
else
    info "No translation directory found, skipping"
fi
ok "Build complete"

# — Generate exact file list from staging
FILES_LIST=$(find "$STAGING" -not -type d | sed "s|^$STAGING||")

# 5 — Write spec
# =============================================================================
info "Writing spec..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/gnome-shell-extension-all-in-one-clipboard.spec" <<SPEC
Name:           gnome-shell-extension-all-in-one-clipboard
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        A clipboard manager combining history, emojis, GIFs, kaomojis and symbols
License:        ISC
BuildArch:      noarch
URL:            https://github.com/NiffirgkcaJ/all-in-one-clipboard

Requires:       gnome-shell

%description
All-in-One Clipboard is a GNOME Shell extension that combines your clipboard
history, emojis, GIFs, kaomojis, and symbols into a single, searchable
interface.

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
    -bb "$RPMBUILD/SPECS/gnome-shell-extension-all-in-one-clipboard.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "gnome-shell-extension-all-in-one-clipboard-*.rpm" | head -1)
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