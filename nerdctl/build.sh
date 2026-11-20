#!/bin/bash
# =============================================================================
#  nerdctl/build.sh — upstream nerdctl binary + generated completions
# =============================================================================
set -euo pipefail

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

rm -rf /root
mkdir -p /root/

WORKDIR="$(mktemp -d /tmp/nerdctl-build.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# 1 — Build dependencies
# =============================================================================
info "Installing build dependencies..."
dnf install -y --setopt=install_weak_deps=False -q \
    rpm-build curl coreutils
ok "Build dependencies installed"

RPMBUILD="$WORKDIR/rpmbuild"
SOURCES="$RPMBUILD/SOURCES"
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# 2 — Detect latest upstream release
# =============================================================================
CURL_AUTH=()
[[ -n "${GITHUB_TOKEN:-}" ]] && CURL_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

info "Detecting latest containerd/nerdctl release..."
TAG="$(curl -fsSL "${CURL_AUTH[@]}" \
    -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/containerd/nerdctl/releases/latest \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)"
[[ -n "$TAG" ]] || die "Failed to detect nerdctl release tag"
VER="${TAG#v}"
[[ -n "$VER" && "$VER" != "$TAG" ]] || die "Unexpected nerdctl tag format: $TAG"
ok "nerdctl tag: $TAG (version $VER)"

# 3 — Download and verify upstream binary tarball
# =============================================================================
TARBALL="nerdctl-${VER}-linux-amd64.tar.gz"
BASE="https://github.com/containerd/nerdctl/releases/download/${TAG}"

info "Downloading $TARBALL and SHA256SUMS..."
curl -fsSL "$BASE/$TARBALL" -o "$WORKDIR/$TARBALL"
curl -fsSL "$BASE/SHA256SUMS" -o "$WORKDIR/SHA256SUMS"
ok "Downloads complete"

info "Verifying checksum..."
(cd "$WORKDIR" && grep -F "  ${TARBALL}" SHA256SUMS | sha256sum -c -) \
    || die "Checksum verification failed for $TARBALL"
ok "Checksum verified"

# 4 — Extract and generate completions
# =============================================================================
info "Extracting upstream tarball..."
EXTRACT="$WORKDIR/extract"
mkdir -p "$EXTRACT"
tar xzf "$WORKDIR/$TARBALL" -C "$EXTRACT"

for f in nerdctl containerd-rootless-setuptool.sh containerd-rootless.sh; do
    [[ -f "$EXTRACT/$f" ]] || die "Missing expected file in tarball: $f"
    chmod +x "$EXTRACT/$f"
done
ok "Upstream files extracted"

info "Generating completions..."
COMP="$WORKDIR/completions"
mkdir -p "$COMP"/{bash,zsh,fish}

"$EXTRACT/nerdctl" completion bash > "$COMP/bash/nerdctl"
"$EXTRACT/nerdctl" completion zsh  > "$COMP/zsh/_nerdctl"
"$EXTRACT/nerdctl" completion fish > "$COMP/fish/nerdctl.fish"

for f in "$COMP/bash/nerdctl" "$COMP/zsh/_nerdctl" "$COMP/fish/nerdctl.fish"; do
    [[ -s "$f" ]] || die "Empty generated completion: $f"
done
ok "Completions generated"

# 5 — Stage sources
# =============================================================================
info "Staging RPM sources..."
install -m755 "$EXTRACT/nerdctl"                      "$SOURCES/nerdctl"
install -m755 "$EXTRACT/containerd-rootless-setuptool.sh" "$SOURCES/containerd-rootless-setuptool.sh"
install -m755 "$EXTRACT/containerd-rootless.sh"       "$SOURCES/containerd-rootless.sh"
install -m644 "$COMP/bash/nerdctl"                    "$SOURCES/bash-completion-nerdctl"
install -m644 "$COMP/zsh/_nerdctl"                    "$SOURCES/zsh-completion-_nerdctl"
install -m644 "$COMP/fish/nerdctl.fish"               "$SOURCES/fish-completion-nerdctl.fish"
ok "Sources staged"

# 6 — Inline spec
# =============================================================================
cat > "$RPMBUILD/SPECS/nerdctl.spec" <<SPEC
Name:           nerdctl
Version:        ${VER}
Release:        1.mink%{?dist}
Summary:        Docker-compatible CLI for containerd
License:        Apache-2.0
URL:            https://github.com/containerd/nerdctl
BuildArch:      x86_64
Requires:       containernetworking-plugins

Source0:        nerdctl
Source1:        containerd-rootless-setuptool.sh
Source2:        containerd-rootless.sh
Source3:        bash-completion-nerdctl
Source4:        zsh-completion-_nerdctl
Source5:        fish-completion-nerdctl.fish

%description
nerdctl is a Docker-compatible command-line interface for containerd. This
package ships the upstream binary, the upstream rootless helper scripts, and
completions generated at build time. containerd and runc are provided by the
base image; CNI plugins are required for container networking.

%install
install -Dm755 %{SOURCE0} %{buildroot}/usr/bin/nerdctl
install -Dm755 %{SOURCE1} %{buildroot}/usr/bin/containerd-rootless-setuptool.sh
install -Dm755 %{SOURCE2} %{buildroot}/usr/bin/containerd-rootless.sh
install -Dm644 %{SOURCE3} %{buildroot}/usr/share/bash-completion/completions/nerdctl
install -Dm644 %{SOURCE4} %{buildroot}/usr/share/zsh/site-functions/_nerdctl
install -Dm644 %{SOURCE5} %{buildroot}/usr/share/fish/vendor_completions.d/nerdctl.fish

%files
/usr/bin/nerdctl
/usr/bin/containerd-rootless-setuptool.sh
/usr/bin/containerd-rootless.sh
/usr/share/bash-completion/completions/nerdctl
/usr/share/zsh/site-functions/_nerdctl
/usr/share/fish/vendor_completions.d/nerdctl.fish

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VER}-1
- Automated build from ${TAG}
SPEC

# 7 — Build
# =============================================================================
info "Building RPM..."
rpmbuild --define "_topdir $RPMBUILD" -bb "$RPMBUILD/SPECS/nerdctl.spec" 2>&1
BUILT="$(find "$RPMBUILD/RPMS" -name 'nerdctl-*.rpm' -print -quit)"
[[ -f "$BUILT" ]] || die "No binary RPM produced"
cp "$BUILT" /output/
ok "RPM ready: /output/$(basename "$BUILT")"

for f in /output/*.rpm; do
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

rpm -qp --info /output/nerdctl-*.rpm
rpm -qp --list /output/nerdctl-*.rpm
