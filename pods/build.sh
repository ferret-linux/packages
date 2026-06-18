#!/bin/bash
# =============================================================================
#  pods/build.sh
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/pods-build"
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
    gtksourceview5-devel \
    vte291-gtk4-devel \
    desktop-file-utils \
    blueprint-compiler \
    git \
    --setopt=install_weak_deps=False -q
ok "Dependencies installed"

# 2 — Detect latest stable tag
# =============================================================================
info "Detecting latest stable tag..."
VERSION=$(git ls-remote --tags https://github.com/marhkb/pods.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -v -- '-' \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's/^v//' \
    | sort -V \
    | tail -1)

[[ -n "$VERSION" ]] || die "Failed to detect latest stable version"
ok "Version: $VERSION"

TAG=$(git ls-remote --tags https://github.com/marhkb/pods.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -v -- '-' \
    | grep -E "^v?${VERSION}$" \
    | head -1)

[[ -n "$TAG" ]] || die "Could not resolve tag for version $VERSION"
ok "Tag: $TAG"

# 3 — Clone source
# =============================================================================
info "Cloning pods at $TAG..."
git clone --depth 1 --branch "$TAG" \
    https://github.com/marhkb/pods.git \
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

# — Generate exact file list from staging
FILES_LIST=$(find "$STAGING" -not -type d | sed "s|^$STAGING||")

# 5 — Write spec
# =============================================================================
info "Writing spec..."
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$RPMBUILD/SPECS/pods.spec" <<SPEC
Name:           pods
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        A frontend for Podman and Docker
License:        GPL-3.0-or-later
BuildArch:      x86_64
URL:            https://github.com/marhkb/pods

Requires:       gtk4
Requires:       libadwaita
Requires:       gtksourceview5
Requires:       vte291-gtk4
Requires:       podman

%description
Pods is a frontend for Podman and Docker. It uses libadwaita for its user
interface and strives to meet the design principles of GNOME. It allows you
to manage images, containers and pods, view logs, monitor processes, and
control the full container lifecycle.

%install
cp -a "${STAGING}/." "%{buildroot}/"

%files
${FILES_LIST}

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-1
- Automated build from tag ${TAG}
SPEC

# 6 — Build RPM
# =============================================================================
info "Building RPM..."
rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/pods.spec" \
    2>&1

RPM_FILE=$(find "$RPMBUILD/RPMS" -name "pods-*.rpm" | head -1)
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