#!/bin/bash
# =============================================================================
#  lazydocker/build.sh
#
#  Fedora doesn't package lazydocker, so wrap upstream's official Linux
#  x86_64 release binary in a small RPM.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.github/scripts/nvr.sh"

NAME=lazydocker
RELEASE=1.mink

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

if ! (( NVR_MODE )); then
    rm -rf /root
    mkdir -p /root/
fi

WORKDIR=/tmp/lazydocker-build
RPMBUILD="$WORKDIR/rpmbuild"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

UPSTREAM="jesseduffield/lazydocker"

# 1 — Build dependencies
# =============================================================================
info "Installing build dependencies..."
if (( NVR_MODE )); then
    dnf install -y --setopt=install_weak_deps=False -q curl
else
    dnf install -y --setopt=install_weak_deps=False -q \
        curl tar gzip rpm-build
fi
ok "Dependencies installed"

# 2 — Resolve + download the latest release
# =============================================================================
info "Detecting latest lazydocker release..."
TAG="$(curl -fsSI -o /dev/null -w '%{redirect_url}' \
    "https://github.com/${UPSTREAM}/releases/latest" \
    | sed 's#.*/tag/##')"
[[ -n "$TAG" ]] || die "Could not detect latest lazydocker release"
VERSION="${TAG#v}"
ok "Version: $VERSION"

emit_nvr "$NAME" "$VERSION" "$RELEASE" "$NVR_ARCH"
nvr_done

ASSET="lazydocker_${VERSION}_Linux_x86_64.tar.gz"
info "Downloading ${ASSET}..."
curl -fLsS -o "$WORKDIR/$ASSET" \
    "https://github.com/${UPSTREAM}/releases/download/${TAG}/${ASSET}"
mkdir -p "$WORKDIR/unpacked"
tar -xzf "$WORKDIR/$ASSET" -C "$WORKDIR/unpacked"
BINARY="$(find "$WORKDIR/unpacked" -type f -name lazydocker -print -quit)"
[[ -x "$BINARY" ]] || die "lazydocker binary not found in release tarball"
"$BINARY" --version >/dev/null 2>&1 || "$BINARY" version >/dev/null 2>&1 \
    || die "Downloaded lazydocker does not run"
ok "Upstream binary verified"

# 3 — Build RPM
# =============================================================================
info "Building RPM..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp "$BINARY" "$RPMBUILD/SOURCES/lazydocker"

cat > "$RPMBUILD/SPECS/lazydocker.spec" <<SPEC
Name:           lazydocker
Version:        ${VERSION}
Release:        ${RELEASE}%{?dist}
Summary:        Simple terminal UI for Docker and docker-compose
License:        MIT
URL:            https://github.com/${UPSTREAM}
Source0:        lazydocker
BuildArch:      x86_64

%description
lazydocker is a simple terminal UI for both docker and docker-compose,
written in Go with the gocui library.

%install
mkdir -p %{buildroot}%{_bindir}
install -m 0755 %{SOURCE0} %{buildroot}%{_bindir}/lazydocker

%files
%{_bindir}/lazydocker

%changelog
* %(date "+%a %b %d %Y") Ferret Linux <ferret-linux> - %{version}-1
- Package upstream ${VERSION} Linux x86_64 release binary
SPEC

rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/lazydocker.spec" 2>&1 \
    | grep -vE '^(warning: )?(%source_date_epoch_from_changelog|Wrote:)' || true

RPM_FILE="$(find "$RPMBUILD/RPMS" -name 'lazydocker-*.rpm' -print -quit)"
[[ -f "$RPM_FILE" ]] || die "RPM not found after build"

cp "$RPM_FILE" /output/
ok "RPM ready: /output/$(basename "$RPM_FILE")"
rpm -qp --info "/output/$(basename "$RPM_FILE")"
rpm -qp --list "/output/$(basename "$RPM_FILE")"
