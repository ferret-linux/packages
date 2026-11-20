#!/bin/bash
# =============================================================================
#  incus-ui/build.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.github/scripts/nvr.sh"

NAME=incus-ui
RELEASE=1.mink

WORKDIR="/tmp/incus-ui-build"
STAGING="$WORKDIR/staging"
RPMBUILD="$WORKDIR/rpmbuild"
GITHUB_REPO="zabbly/incus-ui-canonical"
mkdir -p "$WORKDIR"

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

if ! (( NVR_MODE )); then
    rm -rf /root
    mkdir -p /root/
fi

# 1 — Install build dependencies
# =============================================================================
info "Installing build dependencies..."
if (( NVR_MODE )); then
    dnf install -y --setopt=install_weak_deps=False -q git
else
    dnf install -y \
        nodejs22 \
        nodejs22-npm \
        nodejs22-npm-bin \
        yarnpkg \
        rpm-build \
        git \
        --setopt=install_weak_deps=False -q
fi
ok "Dependencies installed"

# 2 — Detect latest incus-ui-canonical tag
# =============================================================================
# Tags are read over git rather than the REST API: unauthenticated API calls
# from shared CI runners are rate limited (403). sort -V also makes this
# deterministic instead of relying on API tag ordering.
info "Detecting latest incus-ui-canonical tag..."
VERSION="$(git ls-remote --tags "https://github.com/${GITHUB_REPO}.git" \
    | sed 's|.*refs/tags/||' \
    | grep '^incus-' | grep -v '\^{}' \
    | sed 's/^incus-//' \
    | sort -V | tail -1)"

[[ -n "$VERSION" ]] || die "Failed to detect latest UI version"
ok "Version: $VERSION"

TAG="incus-${VERSION}"

emit_nvr "$NAME" "$VERSION" "$RELEASE" "noarch"
nvr_done

# 3 — Download & extract source
# =============================================================================
info "Downloading incus-ui-canonical ${VERSION}..."
SRC_TARBALL="$WORKDIR/source.tar.gz"
curl -sfL -o "$SRC_TARBALL" \
    "https://github.com/${GITHUB_REPO}/archive/refs/tags/${TAG}.tar.gz"
[[ -s "$SRC_TARBALL" ]] || die "Failed to download source tarball"

tar xzf "$SRC_TARBALL" -C "$WORKDIR"
SRC_DIR="$WORKDIR/incus-ui-canonical-${TAG}"
[[ -d "$SRC_DIR" ]] || die "Expected directory $SRC_DIR not found after extraction"
ok "Source extracted"

# 4 — Apply LXD -> Incus rebranding
# =============================================================================
info "Applying LXD -> Incus rebranding..."
find "$SRC_DIR" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.scss" \) -print0 \
    | xargs -0 sed -i \
        -e 's/devlxd/guestapi/g' \
        -e 's/dev\/lxd/dev\/incus/g' \
        -e 's/LXD/Incus/g' \
        -e 's/Lxd/Incus/g' \
        -e 's/lxd/incus/g'
ok "Rebranding applied"

# 5 — Build
# =============================================================================
info "Installing dependencies (yarn install)..."
cd "$SRC_DIR"
yarn install --frozen-lockfile

info "Initializing dummy git repo (required by vite.config.ts for git hash)..."
git init -q
git -c user.email="build@localhost" -c user.name="build" \
    commit --allow-empty -q -m "build"

info "Building UI (yarn build)..."
yarn build

BUILD_OUTPUT="$SRC_DIR/build/ui"
[[ -d "$BUILD_OUTPUT" ]] || die "Build output directory $BUILD_OUTPUT not found"
ok "Build complete"

# 6 — Stage files
# =============================================================================
info "Staging files..."
mkdir -p "$STAGING/usr/share/incus/ui"
cp -rp "$BUILD_OUTPUT/." "$STAGING/usr/share/incus/ui/"

mkdir -p "$STAGING/usr/lib/systemd/system/incus.service.d"
cat > "$STAGING/usr/lib/systemd/system/incus.service.d/ui.conf" <<'EOF'
[Service]
Environment=INCUS_UI=/usr/share/incus/ui
EOF
ok "Files staged"

# — Generate exact file list from staging
FILES_LIST=$(find "$STAGING" -not -type d | sed "s|^$STAGING||")

# 7 — Write spec
# =============================================================================
info "Writing spec..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/incus-ui.spec" <<SPEC
Name:           incus-ui
Version:        ${VERSION}
Release:        ${RELEASE}%{?dist}
Summary:        Incus web management UI
# Based on the Canonical LXD UI (AGPL-3.0), rebranded for Incus
License:        AGPL-3.0-only
BuildArch:      noarch
URL:            https://github.com/${GITHUB_REPO}

Requires:       incus

%description
Web-based graphical user interface for managing Incus containers
and virtual machines. Based on the Canonical LXD UI, rebranded for
Incus. Works with Fedora's stock incus package.

After installing, restart the incus service to activate the UI:
  systemctl restart incus.service

The UI is then accessible through the Incus HTTPS API endpoint.

%install
cp -a "${STAGING}/." "%{buildroot}/"

%files
${FILES_LIST}

%post
%systemd_post incus.service

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-${RELEASE}
- Automated build from tag ${TAG}
SPEC

# 8 — Build RPM
# =============================================================================
info "Building RPM..."
rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/incus-ui.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "incus-ui-*.rpm" | head -1)
[[ -f "$RPM_FILE" ]] || die "RPM not found after build"

cp "$RPM_FILE" /output/

# 9 — Sanitize filename & summarize
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