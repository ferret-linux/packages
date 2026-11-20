#!/bin/bash
# =============================================================================
#  helium-drm/build.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.github/scripts/nvr.sh"

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

if ! (( NVR_MODE )); then
    rm -rf /root
    mkdir -p /root/
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# 1 — Dependencies
# =============================================================================
info "Installing dependencies..."
if (( NVR_MODE )); then
    dnf install -y --setopt=install_weak_deps=False -q \
        dnf5-plugins fedora-workstation-repositories
else
    dnf install -y --setopt=install_weak_deps=False -q \
        python3 dnf5-plugins rpmrebuild fedora-workstation-repositories
fi

info "Enabling imput/helium COPR..."
dnf copr enable -y imput/helium -q

info "Enabling Google Chrome repo..."
dnf config-manager setopt google-chrome.enabled=1

if (( NVR_MODE )); then
    # The COPR exposes both a .src.rpm and the binary RPM; --url may list the
    # source first. Pick the x86_64 binary explicitly so the probe matches the
    # x86_64 RPM the real build produces from the installed helium-bin.
    HELIUM_FILE="$(
        dnf download --url --arch x86_64 helium-bin 2>/dev/null \
            | sed 's/[?].*$//' \
            | awk -F/ '$NF ~ /^helium-bin-.*\.rpm$/ && $NF !~ /\.src\.rpm$/ { print $NF; exit }'
    )"
    [[ -n "$HELIUM_FILE" ]] || die "Could not resolve helium-bin binary RPM"
    HELIUM_FILE="$(sanitize_rpm_name "$HELIUM_FILE")"
    emit_raw_nvr "helium-drm-${HELIUM_FILE#helium-bin-}"
    nvr_done
fi

info "Installing helium-bin..."
dnf install -y -q helium-bin
ok "helium-bin installed"

# 2 — Version + install dir
# =============================================================================
INSTALLED_VER=$(rpm -q helium-bin --queryformat '%{VERSION}')
ok "helium-bin version: $INSTALLED_VER"

if [[ -n "${HELIUM_VERSION:-}" && "$INSTALLED_VER" != "$HELIUM_VERSION" ]]; then
    die "Version mismatch: expected $HELIUM_VERSION, got $INSTALLED_VER"
fi

HELIUM_DIR=$(rpm -ql helium-bin \
    | grep -E '^(/opt|/usr/share)/[^/]+$' \
    | head -1)
[[ -n "$HELIUM_DIR" ]] || die "Could not determine Helium install dir"
info "Helium install dir: $HELIUM_DIR"

# 3 — Pull WidevineCdm from upstream Chrome RPM
# =============================================================================
info "Downloading google-chrome-stable RPM..."
dnf download -q --destdir="$WORKDIR" google-chrome-stable
CHROME_RPM=$(find "$WORKDIR" -name "google-chrome-stable-*.rpm" | head -1)
[[ -f "$CHROME_RPM" ]] || die "Chrome RPM not found after dnf download"
CHROME_VER=$(rpm -qp "$CHROME_RPM" --queryformat '%{VERSION}' 2>/dev/null)
ok "Chrome version: $CHROME_VER"

info "Extracting WidevineCdm..."
cd "$WORKDIR"
rpm2cpio "$CHROME_RPM" | cpio -id --quiet './opt/google/chrome/WidevineCdm/*'
cd /

WIDEVINE_SRC="$WORKDIR/opt/google/chrome/WidevineCdm"
[[ -d "$WIDEVINE_SRC" ]] || die "WidevineCdm not found in Chrome RPM"

WIDEVINE_VER=$(python3 -c \
    "import json; print(json.load(open('$WIDEVINE_SRC/manifest.json'))['version'])")
ok "Widevine version: $WIDEVINE_VER"

# 4 — Inject WidevineCdm into live helium install
# =============================================================================
info "Installing WidevineCdm into $HELIUM_DIR/WidevineCdm..."
rm -rf "$HELIUM_DIR/WidevineCdm"
cp -r "$WIDEVINE_SRC" "$HELIUM_DIR/WidevineCdm"
ok "WidevineCdm in place"

# 5 — Repack from RPM DB (reads installed files, picks up WidevineCdm)
# =============================================================================
info "Repacking helium-bin as helium-drm..."
rpmrebuild --notest-install \
    --change-spec-preamble="sed \
        -e 's/^Name:.*/Name: helium-drm/' \
        -e 's/^Summary:.*/Summary: Helium browser with Widevine DRM (Widevine ${WIDEVINE_VER})/' \
        -e '/^Conflicts:/d' \
        -e \"\\\$a Provides: helium-bin = ${INSTALLED_VER}\" \
        -e \"\\\$a Conflicts: helium-bin\"" \
    --change-spec-files="cat - <(find ${HELIUM_DIR}/WidevineCdm -type d -printf '%%dir %p\n'; find ${HELIUM_DIR}/WidevineCdm -type f -printf '%p\n')" \
    helium-bin

RPM_FILE=$(find ~/rpmbuild/RPMS -name "helium-drm-*.rpm" 2>/dev/null | head -1)
[[ -f "$RPM_FILE" ]] || die "RPM not found after rpmrebuild"

cp "$RPM_FILE" /output/

for f in /output/*.rpm; do
    [[ -f "$f" ]] || continue
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

ok "RPM ready: /output/$(basename "$RPM_FILE")"
echo ""
rpm -qp --info "/output/$(basename "$RPM_FILE")"