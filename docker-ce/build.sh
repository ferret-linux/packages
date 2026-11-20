#!/bin/bash
# =============================================================================
#  docker-ce/build.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.github/scripts/nvr.sh"

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

if ! (( NVR_MODE )); then
    rm -rf /root
    mkdir -p /root/
fi

# 1 — Add Docker CE repo
# =============================================================================
info "Adding Docker CE repo..."
dnf install -y dnf5-plugins --setopt=install_weak_deps=False -q
dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
dnf config-manager setopt docker-ce-stable.enabled=1
dnf --refresh makecache -q
ok "Docker CE repo added"

# 2 — Download all Docker CE RPMs
# =============================================================================
DOCKER_PKGS=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

if (( NVR_MODE )); then
    emit_dnf_urls "${DOCKER_PKGS[@]}"
    nvr_done
fi

info "Downloading Docker CE packages..."
for pkg in "${DOCKER_PKGS[@]}"; do
    info "  Downloading ${pkg}..."
    dnf download "${pkg}" \
        --destdir /output \
        --arch x86_64 --arch noarch \
        -q
done

for f in /output/*.rpm; do
    [[ -f "$f" ]] || continue
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

ok "RPMs ready:"
ls -lh /output/*.rpm
for rpm in /output/*.rpm; do
    rpm -qp --info "$rpm"
done