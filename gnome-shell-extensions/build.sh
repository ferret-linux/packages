#!/bin/bash
# =============================================================================
#  gnome-shell-extensions/build.sh
#
#  Packages multiple GNOME Shell extensions, sourced live from
#  extensions.gnome.org (NOT GitHub), into individual RPMs.
#
#  Output: /output/<rpm-name>.rpm  — one RPM per extension listed below.
# =============================================================================
set -euo pipefail

EGO_BASE="https://extensions.gnome.org"
ROOT_WORKDIR="/tmp/gnome-shell-extensions-build"
OUTPUT_DIR="/output"
mkdir -p "$ROOT_WORKDIR" "$OUTPUT_DIR"

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[✗] $*" >&2; exit 1; }

rm -rf /root
mkdir -p /root/

# =============================================================================
# Extension list: pk:rpm_name:license
#
#   pk        — the numeric ID from the extension's e.g.o URL
#                 e.g. https://extensions.gnome.org/extension/779/clipboard-indicator/
#                                                              ^^^
#   rpm_name  — RPM package name (gnome-shell-extension-<rpm_name>)
#   license   — best-known SPDX license tag (informational; not verified
#                 against the actual repo by this script — double check if
#                 license compliance matters for your distribution)
#
# Add a new extension by adding one line here. Nothing else needs to change.
# =============================================================================
EXTENSIONS=(
    "779:clipboard-indicator:MIT"
    "7048:rounded-window-corners-reborn:GPL-3.0-or-later"
    "9875:o-tiling:GPL-3.0-or-later"
    "7065:tiling-shell:GPL-3.0-or-later"
    "97:coverflow-alt-tab:GPL-2.0-or-later"
    "5263:gtk4-desktop-icons-ng-ding:GPL-3.0-or-later"
    "7535:accent-directories:GPL-3.0-or-later"
    "7502:auto-accent-colour:GPL-3.0-or-later"
)

# 0 — Install build dependencies (once, shared across all extensions)
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

# =============================================================================
# build_extension PK RPM_NAME LICENSE
#
# Builds a single extension end-to-end: query e.g.o -> download -> compile
# schemas/translations -> stage -> write spec -> rpmbuild -> copy to /output.
# Mirrors the proven logic from the standalone clipboard-indicator and
# rounded-window-corners-reborn scripts.
# =============================================================================
build_extension() {
    local PK="$1"
    local RPM_NAME="$2"
    local LICENSE="$3"

    local WORKDIR="$ROOT_WORKDIR/$RPM_NAME"
    local STAGING="$WORKDIR/staging"
    local RPMBUILD="$WORKDIR/rpmbuild"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    echo ""
    echo "================================================================"
    info "Building: $RPM_NAME (pk=$PK)"
    echo "================================================================"

    # 1 — Query extensions.gnome.org for extension metadata + latest version
    # -------------------------------------------------------------------
    info "Querying extension-info for pk=${PK}..."
    local INFO_JSON="$WORKDIR/extension-info.json"
    if ! curl -fsSL "${EGO_BASE}/extension-info/?pk=${PK}" -o "$INFO_JSON"; then
        warn "Failed to fetch extension-info for pk=$PK — skipping $RPM_NAME"
        return 1
    fi

    local UUID
    UUID=$(jq -r '.uuid' "$INFO_JSON")
    if [[ -z "$UUID" || "$UUID" == "null" ]]; then
        warn "Failed to parse UUID from extension-info for pk=$PK — skipping $RPM_NAME"
        return 1
    fi
    ok "UUID: $UUID"

    # The shell_version_map lists, per supported GNOME Shell version, the
    # extension "version" (build number) and a "pk" (version_tag) — the pk
    # of that *specific build*, used by the download endpoint. This pk is
    # NOT the same as the extension's own top-level pk.
    # We want the entry with the single highest "version" number across all
    # shell versions — that's the latest published release — and we need
    # its corresponding "pk" to build the download URL.
    local VERSION
    VERSION=$(jq -r '.shell_version_map | to_entries | map(.value.version) | max' "$INFO_JSON")
    if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
        warn "Failed to determine latest version for pk=$PK — skipping $RPM_NAME"
        return 1
    fi
    ok "Latest extension version: $VERSION"

    local VERSION_TAG
    VERSION_TAG=$(jq -r --argjson v "$VERSION" \
        '.shell_version_map | to_entries | map(select(.value.version == $v)) | .[0].value.pk' \
        "$INFO_JSON")
    if [[ -z "$VERSION_TAG" || "$VERSION_TAG" == "null" ]]; then
        warn "Failed to determine version_tag (pk) for $RPM_NAME — skipping"
        return 1
    fi
    ok "Version tag (download pk): $VERSION_TAG"

    local DESCRIPTION NAME HOMEPAGE_LINK
    DESCRIPTION=$(jq -r '.description // "No description provided."' "$INFO_JSON")
    NAME=$(jq -r '.name' "$INFO_JSON")
    HOMEPAGE_LINK="${EGO_BASE}/extension/${PK}/$(jq -r '.link' "$INFO_JSON" | sed -E 's#^/extension/[0-9]+/##; s#/$##')"

    # 2 — Download the extension package straight from the e.g.o CDN
    # -------------------------------------------------------------------
    # Live download endpoint (this is the URL the site's own "Download"
    # button uses) — takes the per-build "pk" (version_tag), NOT the bare
    # version number:
    #   download-extension/{uuid}.shell-extension.zip?version_tag={pk}
    local ZIP_URL="${EGO_BASE}/download-extension/${UUID}.shell-extension.zip?version_tag=${VERSION_TAG}"
    local ZIP_FILE="$WORKDIR/extension.zip"

    info "Downloading ${ZIP_URL} ..."
    if ! curl -fsSL "$ZIP_URL" -o "$ZIP_FILE"; then
        warn "Failed to download extension package for $RPM_NAME — skipping"
        return 1
    fi
    ok "Downloaded extension zip"

    # 3 — Extract & stage
    # -------------------------------------------------------------------
    local SRC="$WORKDIR/src"
    mkdir -p "$SRC"
    unzip -q -o "$ZIP_FILE" -d "$SRC"
    ok "Extracted extension package"

    local PARSED_UUID
    PARSED_UUID=$(grep -o '"uuid"[[:space:]]*:[[:space:]]*"[^"]*"' "$SRC/metadata.json" | sed 's/.*"\([^"]*\)"$/\1/')
    if [[ -z "$PARSED_UUID" ]]; then
        warn "Failed to parse UUID from metadata.json for $RPM_NAME — skipping"
        return 1
    fi
    [[ "$PARSED_UUID" == "$UUID" ]] || info "Note: metadata.json uuid ($PARSED_UUID) differs from e.g.o uuid ($UUID), using metadata.json value"
    UUID="$PARSED_UUID"
    ok "UUID confirmed: $UUID"

    local INSTALL_DIR="$STAGING/usr/share/gnome-shell/extensions/$UUID"
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
    for item in locale metadata.json stylesheet.css stylesheet-dark.css stylesheet-light.css \
                LICENSE.rst LICENSE LICENSE.md schemas icons resources ui; do
        [[ -e "$SRC/$item" ]] && cp -r "$SRC/$item" "$INSTALL_DIR/"
    done
    shopt -u nullglob
    ok "Staging complete"

    # Sanitize staged .js files for rpmbuild's brp-mangle-shebangs check.
    #
    # GNOME Shell extension .js files are loaded as ES modules by the Shell's
    # own JS engine — they are never executed directly via their own shebang
    # line, regardless of what that line says. Some upstream projects (e.g.
    # those built with meson) ship a helper script with an unsubstituted
    # build-time placeholder shebang, like "#!@GJS@ -m" instead of the final
    # "#!/usr/bin/env gjs -m" meson would normally substitute at install
    # time. rpmbuild's %install phase runs a strict brp-mangle-shebangs
    # check that hard-fails the build on any shebang not starting with '/',
    # even though the broken line is harmless at runtime (nothing in the
    # actual install-and-run path executes these files as "./file.js").
    #
    # Fix: strip the executable bit from every staged .js file. This matches
    # how these files actually get used in practice, and sidesteps the
    # shebang check entirely (rpmbuild only inspects shebangs on files that
    # are executable). Belt-and-suspenders: also neutralize any leftover
    # unsubstituted "#!@SOMETHING@" template shebang text, in case some
    # other tooling down the line still cares about file content rather
    # than the executable bit.
    info "Sanitizing staged .js files (shebangs / executable bits)..."
    while IFS= read -r -d '' js_file; do
        if head -c 64 "$js_file" | grep -qE '^#!.*@[A-Za-z0-9_]+@'; then
            info "  fixing unsubstituted template shebang in ${js_file#"$INSTALL_DIR"/}"
            sed -i '1s|^#!.*@[A-Za-z0-9_]\+@.*$|#!/usr/bin/env gjs|' "$js_file"
        fi
        chmod -x "$js_file"
    done < <(find "$INSTALL_DIR" -name '*.js' -print0)
    ok "Sanitization complete"

    # — Generate exact file list from staging
    local FILES_LIST
    FILES_LIST=$(find "$STAGING" -not -type d | sed "s|^$STAGING||")

    # 4 — Write spec
    # -------------------------------------------------------------------
    info "Writing spec..."
    mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    cat > "$RPMBUILD/SPECS/gnome-shell-extension-${RPM_NAME}.spec" <<SPEC
Name:           gnome-shell-extension-${RPM_NAME}
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        ${NAME}
License:        ${LICENSE}
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
- Automated build from extensions.gnome.org (pk=${PK}, version=${VERSION})
SPEC

    # 5 — Build RPM
    # -------------------------------------------------------------------
    info "Building RPM..."
    rpmbuild \
        --define "_topdir $RPMBUILD" \
        -bb "$RPMBUILD/SPECS/gnome-shell-extension-${RPM_NAME}.spec" \
        2>&1

    local RPM_FILE
    RPM_FILE=$(find "$RPMBUILD/RPMS" -name "gnome-shell-extension-${RPM_NAME}-*.rpm" | head -1)
    if [[ ! -f "$RPM_FILE" ]]; then
        warn "RPM not found after build for $RPM_NAME — skipping"
        return 1
    fi

    cp "$RPM_FILE" "$OUTPUT_DIR/"
    ok "RPM built: $(basename "$RPM_FILE")"
    return 0
}

# =============================================================================
# Main loop — build every extension, keep going on individual failures,
# report a final summary.
# =============================================================================
declare -a SUCCEEDED=()
declare -a FAILED=()

for entry in "${EXTENSIONS[@]}"; do
    IFS=':' read -r pk rpm_name license <<< "$entry"
    if build_extension "$pk" "$rpm_name" "$license"; then
        SUCCEEDED+=("$rpm_name")
    else
        FAILED+=("$rpm_name")
    fi
done

# 6 — Sanitize filenames in /output (strip RPM epoch/version chars that
#     aren't filesystem-friendly, e.g. ':' from epoch, '^' from pre-release)
# =============================================================================
for f in "$OUTPUT_DIR"/*.rpm; do
    [[ -f "$f" ]] || continue
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "$OUTPUT_DIR/$clean"
done

# 7 — Final summary
# =============================================================================
echo ""
echo "================================================================"
echo " BUILD SUMMARY"
echo "================================================================"
ok "Succeeded (${#SUCCEEDED[@]}): ${SUCCEEDED[*]:-none}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    warn "Failed (${#FAILED[@]}): ${FAILED[*]}"
fi

echo ""
info "RPMs in ${OUTPUT_DIR}:"
ls -la "$OUTPUT_DIR"/*.rpm 2>/dev/null || warn "No RPMs were produced."

# Exit non-zero overall if anything failed, so CI surfaces it,
# but only after every extension had a chance to build.
if [[ ${#FAILED[@]} -gt 0 ]]; then
    exit 1
fi