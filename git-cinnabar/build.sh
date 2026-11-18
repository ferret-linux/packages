#!/bin/bash
# =============================================================================
#  git-cinnabar/build.sh
#
#  Upstream ships official Linux x86_64 release tarballs, so this wraps that
#  binary in a proper RPM. Fedora dropped the git-cinnabar package in 45, and
#  the dx image needs it back.
# =============================================================================
set -euo pipefail

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

rm -rf /root
mkdir -p /root/

WORKDIR=/tmp/git-cinnabar-build
RPMBUILD="$WORKDIR/rpmbuild"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

UPSTREAM="glandium/git-cinnabar"
ASSET="git-cinnabar.linux.x86_64.tar.xz"

# 1 — Build dependencies
# =============================================================================
info "Installing build dependencies..."
dnf install -y --setopt=install_weak_deps=False -q \
    curl xz rpm-build
ok "Dependencies installed"

# 2 — Resolve the latest release tag without the rate-limited REST API
# =============================================================================
info "Detecting latest git-cinnabar release..."
TAG="$(curl -fsSI -o /dev/null -w '%{redirect_url}' \
    "https://github.com/${UPSTREAM}/releases/latest" \
    | sed 's#.*/tag/##')"
[[ -n "$TAG" ]] || die "Could not detect latest git-cinnabar release"
VERSION="${TAG#v}"
ok "Version: $VERSION"

# 3 — Download the upstream binary
# =============================================================================
info "Downloading ${ASSET}..."
curl -fLsS -o "$WORKDIR/$ASSET" \
    "https://github.com/${UPSTREAM}/releases/download/${TAG}/${ASSET}"
tar -xf "$WORKDIR/$ASSET" -C "$WORKDIR"
BINARY="$WORKDIR/git-cinnabar/git-cinnabar"
[[ -x "$BINARY" ]] || die "git-cinnabar binary not found in release tarball"
"$BINARY" --version >/dev/null || die "Downloaded git-cinnabar does not run"
ok "Upstream binary verified"

# 4 — Build RPM
# =============================================================================
info "Building RPM..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/git-cinnabar.spec" <<SPEC
Name:           git-cinnabar
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Git remote helper for Mercurial repositories
License:        GPL-2.0-only
URL:            https://github.com/${UPSTREAM}
# Upstream also ships this name; install one or the other, not both.
Conflicts:      git-remote-hg
Provides:       git-remote-hg = %{version}-%{release}
Source0:        %{name}
BuildArch:      x86_64

%description
git-cinnabar is a git remote helper for Mercurial repositories. It lets git
clone, fetch and push from Mercurial remotes using the git-cinnabar protocol.

%install
mkdir -p %{buildroot}%{_bindir}
install -m 0755 %{SOURCE0} %{buildroot}%{_bindir}/git-cinnabar
ln -s git-cinnabar %{buildroot}%{_bindir}/git-remote-hg

%files
%{_bindir}/git-cinnabar
%{_bindir}/git-remote-hg

%changelog
* %(date "+%a %b %d %Y") Ferret Linux <ferret-linux> - %{version}-1
- Package upstream ${VERSION} Linux x86_64 release binary
SPEC

cp "$BINARY" "$RPMBUILD/SOURCES/git-cinnabar"

rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/git-cinnabar.spec" 2>&1 \
    | grep -vE '^(warning: )?(%source_date_epoch_from_changelog|Wrote:)' || true

RPM_FILE="$(find "$RPMBUILD/RPMS" -name 'git-cinnabar-*.rpm' | head -1)"
[[ -f "$RPM_FILE" ]] || die "RPM not found after build"

cp "$RPM_FILE" /output/
ok "RPM ready: /output/$(basename "$RPM_FILE")"
rpm -qp --info "/output/$(basename "$RPM_FILE")"
rpm -qp --list "/output/$(basename "$RPM_FILE")"
