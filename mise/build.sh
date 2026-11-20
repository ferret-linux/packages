#!/bin/bash
# =============================================================================
#  mise/build.sh — republish upstream's COPR mise as a bootc-managed RPM
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.github/scripts/nvr.sh"

NAME=mise
RELEASE=1.mink

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

if ! (( NVR_MODE )); then
    rm -rf /root
    mkdir -p /root/
fi

WORKDIR="$(mktemp -d /tmp/mise-build.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# 1 — Resolve version from upstream COPR (also used by --print-nvr)
# =============================================================================
info "Installing minimal COPR tooling..."
if (( NVR_MODE )); then
    dnf install -y --setopt=install_weak_deps=False -q dnf5-plugins
else
    dnf install -y --setopt=install_weak_deps=False -q \
        dnf5-plugins rpm-build cpio
fi
ok "Minimal COPR tooling installed"

info "Enabling upstream COPR (build-time only)..."
dnf -y copr enable jdxcode/mise
ok "COPR enabled"

info "Downloading latest mise source RPM..."
dnf --refresh -q download --source mise --destdir "$WORKDIR"
SRPM="$(find "$WORKDIR" -maxdepth 1 -name 'mise-*.src.rpm' -print -quit)"
[[ -f "$SRPM" ]] || die "No mise source RPM downloaded"
ok "Source RPM: $(basename "$SRPM")"

VERSION="$(basename "$SRPM" | sed -E 's/^mise-([0-9][^-]*)-.*$/\1/')"
[[ -n "$VERSION" && "$VERSION" != "$(basename "$SRPM")" ]] \
    || die "Could not determine version from $(basename "$SRPM")"
ok "Version: $VERSION"

emit_nvr "$NAME" "$VERSION" "$RELEASE" "$NVR_ARCH"
nvr_done

# 2 — Build dependencies
# =============================================================================
info "Installing build dependencies..."
dnf install -y --setopt=install_weak_deps=False -q \
    patch python3 gcc nasm openssl-devel cmake cargo rust git
ok "Build dependencies installed"

# 3 — Extract and patch the spec
# =============================================================================
cd "$WORKDIR"
rpm2cpio "$SRPM" | cpio -idm --quiet
SPEC="$(find "$WORKDIR" -maxdepth 1 -name 'mise.spec' -print -quit)"
[[ -f "$SPEC" ]] || die "mise.spec not found in source RPM"
ok "Spec extracted"

info "Patching spec..."
python3 - "$SPEC" <<'PY'
import sys

path = sys.argv[1]
text = open(path).read()

replacements = [
    (
        'message = "To update mise from COPR, run:\\n\\n  sudo dnf upgrade mise\\n"',
        'message = "mise self-update is not supported for this installation.'
        '\\n\\nmise is managed as part of the operating system image, so /usr is read-only.'
        '\\n\\nUpdate the image instead:\\n\\n  sudo bootc upgrade\\n"',
    ),
    ('Release:        1%{?dist}', 'Release:        1.mink%{?dist}'),
    (
        'cargo build --profile release --frozen --bin mise --ignore-rust-version',
        'export MISE_NO_PIE=1\n'
        'cargo build --profile serious --frozen --bin mise --ignore-rust-version '
        '--no-default-features --features native-tls,vfox/vendored-lua',
    ),
    ('cp target/release/mise ', 'cp target/serious/mise '),
]

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        sys.exit(f"expected exactly one occurrence of {old!r}, found {count}")
    text = text.replace(old, new)

open(path, "w").write(text)
PY
ok "Spec patched (message, release, serious/non-PIE, self-update off)"

# 4 — Build
# =============================================================================
RPMBUILD="$WORKDIR/rpmbuild"
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp "$WORKDIR"/*.tar.gz "$RPMBUILD/SOURCES/"
cp "$SPEC" "$RPMBUILD/SPECS/"

info "Building RPM..."
rpmbuild --define "_topdir $RPMBUILD" -ba "$RPMBUILD/SPECS/mise.spec"
BUILT="$(find "$RPMBUILD/RPMS" -name 'mise-*.rpm' -print -quit)"
[[ -f "$BUILT" ]] || die "No binary RPM produced"
cp "$BUILT" /output/
ok "RPM ready: /output/$(basename "$BUILT")"

for f in /output/*.rpm; do
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

rpm -qp --info /output/mise-*.rpm
rpm -qp --list /output/mise-*.rpm
