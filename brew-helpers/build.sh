#!/bin/bash
# =============================================================================
#  brew-helpers/build.sh — tiny Homebrew lifecycle commands for mink-os
# =============================================================================
set -euo pipefail

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

rm -rf /root
mkdir -p /root/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d /tmp/brew-helpers-build.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# 1 — Build dependencies
# =============================================================================
info "Installing build dependencies..."
dnf install -y --setopt=install_weak_deps=False -q \
    rpm-build curl
ok "Build dependencies installed"

RPMBUILD="$WORKDIR/rpmbuild"
SOURCES="$RPMBUILD/SOURCES"
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# 2 — Upstream completion scripts
# =============================================================================
CURL_AUTH=()
[[ -n "${GITHUB_TOKEN:-}" ]] && CURL_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

info "Detecting latest Homebrew/brew release..."
TAG="$(curl -fsSL "${CURL_AUTH[@]}" \
    -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/Homebrew/brew/releases/latest \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)"
[[ -n "$TAG" ]] || die "Failed to detect Homebrew/brew release tag"
ok "Homebrew/brew tag: $TAG"

RAW="https://raw.githubusercontent.com/Homebrew/brew/${TAG}"
info "Fetching completions..."

curl -fsSL "$RAW/completions/bash/brew"   -o "$SOURCES/bash-completion-brew"
curl -fsSL "$RAW/completions/zsh/_brew"   -o "$SOURCES/zsh-completion-_brew"
curl -fsSL "$RAW/completions/fish/brew.fish" -o "$SOURCES/fish-completion-brew.fish"

for f in "$SOURCES"/bash-completion-brew \
         "$SOURCES"/zsh-completion-_brew \
         "$SOURCES"/fish-completion-brew.fish; do
    [[ -s "$f" ]] || die "Empty or missing completion file: $f"
done
ok "Completions fetched"

# 3 — Helper scripts (extensionless on disk and in the RPM)
# =============================================================================
info "Staging helper scripts..."
for s in brew-install brew-uninstall brew-upgrade brew-cleanup; do
    [[ -f "$SCRIPT_DIR/$s" ]] || die "Missing helper script: $s"
    install -m755 "$SCRIPT_DIR/$s" "$SOURCES/$s"
done
ok "Helper scripts staged"

# 4 — Inline spec
# =============================================================================
cat > "$RPMBUILD/SPECS/brew-helpers.spec" <<SPEC
Name:           brew-helpers
Version:        1.0
Release:        1.mink%{?dist}
Summary:        Tiny Homebrew lifecycle helpers for mink-os
License:        MIT
URL:            https://brew.sh
BuildArch:      x86_64
Requires:       bash
Requires:       python3
Requires:       curl
Requires:       git
Requires:       gum

Source0:        brew-install
Source1:        brew-uninstall
Source2:        brew-upgrade
Source3:        brew-cleanup
Source4:        bash-completion-brew
Source5:        zsh-completion-_brew
Source6:        fish-completion-brew.fish

%description
Small, user-driven helpers for Homebrew on mink-os: install, upgrade, clean,
and uninstall. Homebrew itself is installed on demand from the official
upstream installer and lives outside the immutable image.

%install
install -Dm755 %{SOURCE0} %{buildroot}/usr/bin/brew-install
install -Dm755 %{SOURCE1} %{buildroot}/usr/bin/brew-uninstall
install -Dm755 %{SOURCE2} %{buildroot}/usr/bin/brew-upgrade
install -Dm755 %{SOURCE3} %{buildroot}/usr/bin/brew-cleanup
install -Dm644 %{SOURCE4} %{buildroot}/usr/share/bash-completion/completions/brew
install -Dm644 %{SOURCE5} %{buildroot}/usr/share/zsh/site-functions/_brew
install -Dm644 %{SOURCE6} %{buildroot}/usr/share/fish/vendor_completions.d/brew.fish

%files
/usr/bin/brew-install
/usr/bin/brew-uninstall
/usr/bin/brew-upgrade
/usr/bin/brew-cleanup
/usr/share/bash-completion/completions/brew
/usr/share/zsh/site-functions/_brew
/usr/share/fish/vendor_completions.d/brew.fish

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - 1.0-1
- Automated build
SPEC

# 5 — Build
# =============================================================================
info "Building RPM..."
rpmbuild --define "_topdir $RPMBUILD" -bb "$RPMBUILD/SPECS/brew-helpers.spec" 2>&1
BUILT="$(find "$RPMBUILD/RPMS" -name 'brew-helpers-*.rpm' -print -quit)"
[[ -f "$BUILT" ]] || die "No binary RPM produced"
cp "$BUILT" /output/
ok "RPM ready: /output/$(basename "$BUILT")"

for f in /output/*.rpm; do
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

rpm -qp --info /output/brew-helpers-*.rpm
rpm -qp --list /output/brew-helpers-*.rpm
