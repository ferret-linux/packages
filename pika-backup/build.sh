#!/bin/bash
# =============================================================================
#  pika-backup/build.sh
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/pika-backup-build"
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
    rust cargo \
    meson \
    rpm-build \
    gettext \
    glib2-devel \
    gtk4-devel \
    libadwaita-devel \
    yelp-tools \
    git \
    --setopt=install_weak_deps=False -q
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

# 3 — Clone source
# =============================================================================
info "Cloning pika-backup at $TAG..."
git clone --depth 1 --branch "$TAG" \
    https://github.com/pika-backup/pika-backup.git \
    "$WORKDIR/src"
ok "Source cloned"

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

# 5 — Write spec
# =============================================================================
info "Writing spec..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/pika-backup.spec" <<SPEC
Name:           pika-backup
Version:        ${VERSION}
Release:        1%{?dist}
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
/usr/*
/etc/*

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-1
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