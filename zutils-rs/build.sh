#!/bin/bash
# =============================================================================
#  zutils-rs/build.sh  —  builds zync, zrun, zgpu, zfetch
# =============================================================================
set -euo pipefail

WORKDIR="/tmp/zutils-build"
mkdir -p "$WORKDIR"

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

rm -rf /root
mkdir -p /root/

# 1 — Install build dependencies
# =============================================================================
info "Installing dependencies..."
dnf install -y rustup rpm-build wget musl-gcc musl-devel musl-filesystem musl-libc-static \
    git \
    --setopt=install_weak_deps=False -q

# — Install latest Go toolchain
# =============================================================================
info "[otter] Installing Go toolchain..."
GO_VERSION=$(curl -sf https://go.dev/VERSION?m=text | head -1 | sed 's/^go//')
[[ -n "$GO_VERSION" ]] || die "Failed to detect latest Go version"
ok "[otter] Go version: $GO_VERSION"

curl -sf "https://dl.google.com/go/go${GO_VERSION}.linux-amd64.tar.gz" \
    -o /tmp/go.tar.gz
tar -C /usr/local -xf /tmp/go.tar.gz
export PATH="/usr/local/go/bin:$PATH"
ok "[otter] Go installed: $(go version)"

# 2 — Setup rustup + musl target (once, shared across all packages)
# =============================================================================
info "Setting up rustup..."
rustup-init -y --default-toolchain stable --profile default
source "$HOME/.cargo/env"
rustup target add x86_64-unknown-linux-musl

# =============================================================================
#  build_package <name> <summary> <description> <musl: true|false>
# =============================================================================
build_package() {
    local NAME="$1"
    local SUMMARY="$2"
    local DESCRIPTION="$3"
    local USE_MUSL="$4"

    local REPO="https://github.com/zodium-project/${NAME}-rs/archive/refs/heads/stable.tar.gz"
    local PKG_WORKDIR="$WORKDIR/${NAME}"
    local RPMBUILD="$PKG_WORKDIR/rpmbuild"
    local SRC_DIR="$PKG_WORKDIR/${NAME}-rs-stable"

    info "[$NAME] Downloading source..."
    mkdir -p "$PKG_WORKDIR"
    wget -q "$REPO" -O "$PKG_WORKDIR/stable.tar.gz"
    tar -xf "$PKG_WORKDIR/stable.tar.gz" -C "$PKG_WORKDIR"

    local VERSION
    VERSION=$(grep '^version' "$SRC_DIR/Cargo.toml" \
        | head -1 \
        | sed 's/.*= *"\(.*\)"/\1/')
    [[ -n "$VERSION" ]] || die "[$NAME] Failed to detect version from Cargo.toml"
    info "[$NAME] Version: $VERSION"

    info "[$NAME] Building binary..."
    cd "$SRC_DIR"
    if [[ "$USE_MUSL" == "true" ]]; then
        cargo build --release --locked --target x86_64-unknown-linux-musl
        local BINARY="$SRC_DIR/target/x86_64-unknown-linux-musl/release/${NAME}"
        local BUILD_ARCH="x86_64"
    else
        cargo build --release --locked
        local BINARY="$SRC_DIR/target/release/${NAME}"
        local BUILD_ARCH="x86_64"
    fi
    ok "[$NAME] Binary built: $(ls -lh "$BINARY")"

    info "[$NAME] Building RPM..."
    mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    cat > "$RPMBUILD/SPECS/${NAME}.spec" <<SPEC
Name:           ${NAME}
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        ${SUMMARY}
License:        MPL-2.0
BuildArch:      ${BUILD_ARCH}
URL:            https://github.com/zodium-project/${NAME}-rs

%description
${DESCRIPTION}

%install
install -Dm755 "${BINARY}" %{buildroot}/usr/bin/${NAME}

%files
/usr/bin/${NAME}

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${VERSION}-1
- Automated build
SPEC

    rpmbuild \
        --define "_topdir $RPMBUILD" \
        -bb "$RPMBUILD/SPECS/${NAME}.spec" \
        2>&1

    local RPM_FILE
    RPM_FILE=$(find "$RPMBUILD/RPMS" -name "${NAME}-*.rpm" | head -1)
    [[ -f "$RPM_FILE" ]] || die "[$NAME] RPM not found after build"

    cp "$RPM_FILE" /output/
    ok "[$NAME] RPM ready: /output/$(basename "$RPM_FILE")"
    rpm -qp --info "/output/$(basename "$RPM_FILE")"
    rpm -qp --list "/output/$(basename "$RPM_FILE")"
}

# 3 — Build all packages
# =============================================================================

build_package "zrun" \
    "Fast TUI shell-script launcher written in Rust" \
    "zrun is a fast, polished TUI shell-script launcher written in Rust.
Compiled as a fully static musl binary with zero external runtime deps." \
    true

build_package "zfetch" \
    "A fast and good looking fetch tool written in Rust" \
    "zfetch is a fast, minimal system fetch tool written in Rust with
multiple built-in themes, TUI configuration, and terminal resizing support." \
    false

# — otter
# =============================================================================
info "[otter] Detecting latest tag..."
OTTER_TAG=$(git ls-remote --tags https://github.com/ferret-linux/otter.git \
    | grep -o 'refs/tags/[^^{}]*$' \
    | sed 's|refs/tags/||' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -1)

[[ -n "$OTTER_TAG" ]] || die "[otter] Failed to detect latest tag"
ok "[otter] Tag: $OTTER_TAG"

OTTER_WORKDIR="$WORKDIR/otter"
OTTER_RPMBUILD="$OTTER_WORKDIR/rpmbuild"
mkdir -p "$OTTER_WORKDIR"

info "[otter] Cloning at $OTTER_TAG..."
git clone --depth 1 --branch "$OTTER_TAG" \
    https://github.com/ferret-linux/otter.git \
    "$OTTER_WORKDIR/src"
ok "[otter] Source cloned"

info "[otter] Building binary..."
cd "$OTTER_WORKDIR/src"
make build
ok "[otter] Binary built: $(ls -lh "$OTTER_WORKDIR/src/bin/otter")"

info "[otter] Building RPM..."
mkdir -p "$OTTER_RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cat > "$OTTER_RPMBUILD/SPECS/otter.spec" <<SPEC
Name:           otter
Version:        ${OTTER_TAG}
Release:        1%{?dist}
Summary:        Spin up host-integrated container environments
License:        GPL-3.0-only
BuildArch:      x86_64
URL:            https://github.com/ferret-linux/otter

%description
Otter is a container environment manager for host-integrated containers that
come pre-configured, opinionated, and ready to go. Works with Docker, Podman,
and nerdctl.

%install
install -Dm755 "${OTTER_WORKDIR}/src/bin/otter" %{buildroot}/usr/bin/otter
install -Dm644 "${OTTER_WORKDIR}/src/completions/otter.bash" %{buildroot}/usr/share/bash-completion/completions/otter
install -Dm644 "${OTTER_WORKDIR}/src/completions/otter.zsh"  %{buildroot}/usr/share/zsh/site-functions/_otter
install -Dm644 "${OTTER_WORKDIR}/src/completions/otter.fish" %{buildroot}/usr/share/fish/vendor_completions.d/otter.fish

%files
/usr/bin/otter
/usr/share/bash-completion/completions/otter
/usr/share/zsh/site-functions/_otter
/usr/share/fish/vendor_completions.d/otter.fish

%changelog
* $(date '+%a %b %d %Y') packages <actions@github.com> - ${OTTER_TAG}-1
- Automated build from tag ${OTTER_TAG}
SPEC

rpmbuild \
    --define "_topdir $OTTER_RPMBUILD" \
    -bb "$OTTER_RPMBUILD/SPECS/otter.spec" \
    2>&1

OTTER_RPM=$(find "$OTTER_RPMBUILD/RPMS" -name "otter-*.rpm" | head -1)
[[ -f "$OTTER_RPM" ]] || die "[otter] RPM not found after build"

cp "$OTTER_RPM" /output/
ok "[otter] RPM ready: /output/$(basename "$OTTER_RPM")"
rpm -qp --info "/output/$(basename "$OTTER_RPM")"
rpm -qp --list "/output/$(basename "$OTTER_RPM")"

for f in /output/*.rpm; do
    [[ -f "$f" ]] || continue
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

# 4 — Summary
# =============================================================================
info "Final output:"
ls -lh /output/*.rpm
ok "All RPMs ready in /output/"