#!/bin/bash
# =============================================================================
#  pika-backup/build.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.github/scripts/nvr.sh"

NAME=pika-backup
RELEASE=1.mink

WORKDIR="/tmp/pika-backup-build"
STAGING="$WORKDIR/staging"
RPMBUILD="$WORKDIR/rpmbuild"
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
        rust cargo \
        meson \
        rpm-build \
        gettext \
        glib2-devel \
        openssl-devel \
        gtk4-devel \
        libadwaita-devel \
        yelp-tools \
        git \
        --setopt=install_weak_deps=False -q
fi
ok "Dependencies installed"

# 2 — Detect latest stable tag
# =============================================================================
info "Detecting latest stable tag..."
VERSION=$(git ls-remote --tags https://github.com/pika-backup/pika-backup.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -v -- '-' \
    | sed 's/^v//' \
    | sort -V \
    | tail -1)

[[ -n "$VERSION" ]] || die "Failed to detect latest stable version"
ok "Version: $VERSION"

# Reconstruct the actual tag (may or may not have v prefix)
TAG=$(git ls-remote --tags https://github.com/pika-backup/pika-backup.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -v -- '-' \
    | grep -E "^v?${VERSION}$" \
    | head -1)

[[ -n "$TAG" ]] || die "Could not resolve tag for version $VERSION"
ok "Tag: $TAG"

emit_nvr "$NAME" "$VERSION" "$RELEASE" "$NVR_ARCH"
nvr_done

# 3 — Clone source
# =============================================================================
info "Cloning pika-backup at $TAG..."
git clone --depth 1 --branch "$TAG" \
    https://github.com/pika-backup/pika-backup.git \
    "$WORKDIR/src"
ok "Source cloned"

# 3b — OpenSSL 4.0 in the buildroot
# -----------------------------------------------------------------------------
# Fedora 45 ships OpenSSL 4.0. The openssl-sys pinned in pika-backup's
# Cargo.lock predates 4.x and aborts its build script ("only compatible with
# OpenSSL 1.1.0, 1.1.1, or 3.x"). openssl 0.10.82 / openssl-sys 0.9.118 are the
# pair that gained 4.x support, so bump exactly those two entries in the lock
# file and leave every other dependency untouched.
info "Updating openssl crates for OpenSSL 4.x..."
( cd "$WORKDIR/src" && \
  cargo update -p openssl --precise 0.10.82 && \
  cargo update -p openssl-sys --precise 0.9.118 )
ok "openssl crates updated"

# 4 — Build
# =============================================================================
info "Configuring with meson..."
meson setup "$WORKDIR/build" "$WORKDIR/src" \
    --prefix=/usr \
    -Dprofile=release \
    --buildtype=release

info "Compiling..."
meson compile -C "$WORKDIR/build"

info "Installing to staging..."
mkdir -p "$STAGING"
DESTDIR="$STAGING" meson install -C "$WORKDIR/build"
ok "Build complete"

# — Generate exact file list from staging
FILES_LIST=$(find "$STAGING" -not -type d | sed "s|^$STAGING||")

# 5 — Write spec
# =============================================================================
info "Writing spec..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/pika-backup.spec" <<SPEC
Name:           pika-backup
Version:        ${VERSION}
Release:        ${RELEASE}%{?dist}
Summary:        Simple backups based on borg
License:        GPL-3.0-only
BuildArch:      x86_64
URL:            https://apps.gnome.org/PikaBackup/

Requires:       borgbackup
Requires:       gtk4
Requires:       libadwaita

%description
Pika Backup is designed to save your personal data and does not support
complete system recovery. It is powered by the well-tested BorgBackup software.

%install
cp -a "${STAGING}/." "%{buildroot}/"

%files
${FILES_LIST}

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-${RELEASE}
- Automated build from tag ${TAG}
SPEC

# 6 — Build RPM
# =============================================================================
info "Building RPM..."
rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/pika-backup.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "pika-backup-*.rpm" | head -1)
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