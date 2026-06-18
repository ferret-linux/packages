#!/bin/bash
# =============================================================================
#  resources/build.sh
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/resources-build"
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
    git \
    --setopt=install_weak_deps=False -q
ok "Dependencies installed"

# 2 — Detect latest stable tag
# =============================================================================
info "Detecting latest stable tag..."
# Source is now at GNOME Incubator but has no formal releases yet;
# the archived GitHub repo retains all tags and is the authoritative tag source.
VERSION=$(git ls-remote --tags https://github.com/nokyan/resources.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -v -- '-' \
    | sed 's/^v//' \
    | sort -V \
    | tail -1)

[[ -n "$VERSION" ]] || die "Failed to detect latest stable version"
ok "Version: $VERSION"

TAG=$(git ls-remote --tags https://github.com/nokyan/resources.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -v -- '-' \
    | grep -E "^v?${VERSION}$" \
    | head -1)

[[ -n "$TAG" ]] || die "Could not resolve tag for version $VERSION"
ok "Tag: $TAG"

# 3 — Clone source
# =============================================================================
info "Cloning resources at $TAG..."
git clone --depth 1 --branch "$TAG" \
    https://gitlab.gnome.org/GNOME/Incubator/resources.git \
    "$WORKDIR/src"
ok "Source cloned"

# 4 — Build
# =============================================================================
info "Configuring with meson..."
meson setup "$WORKDIR/build" "$WORKDIR/src" \
    --prefix=/usr \
    -Dprofile=default \
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

cat > "$RPMBUILD/SPECS/resources.spec" <<SPEC
Name:           resources
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Monitor your system resources and processes
License:        GPL-3.0-only
BuildArch:      x86_64
URL:            https://apps.gnome.org/Resources/

Requires:       gtk4
Requires:       libadwaita
Requires:       dmidecode

%description
Resources is a simple yet powerful monitor for your system resources and
processes. It displays CPU, memory, GPU, NPU, network, disk, and battery
usage with graphs, and can list and terminate running applications.

%install
cp -a "${STAGING}/." "%{buildroot}/"

%files
/usr/*

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-1
- Automated build from tag ${TAG}
SPEC

# 6 — Build RPM
# =============================================================================
info "Building RPM..."
rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/resources.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "resources-*.rpm" | head -1)
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