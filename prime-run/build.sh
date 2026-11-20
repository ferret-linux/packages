#!/bin/bash
# =============================================================================
#  prime-run/build.sh
#
#  prime-run is a tiny Terra helper that launches apps on the discrete GPU.
#  Terra isn't allowed as an image repo, so republish it into Ferret's repo
#  at build time like the other Terra-sourced packages.
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

WORKDIR=/tmp/prime-run-build
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# 1 — Build dependencies + Terra (build-time only)
# =============================================================================
info "Installing build dependencies..."
dnf install -y --setopt=install_weak_deps=False -q dnf5-plugins
ok "Dependencies installed"

info "Adding Terra repo (build-time only)..."
dnf install -y --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
    terra-release -q
dnf reinstall -y terra-release -q
dnf makecache --refresh >/dev/null 2>&1
ok "Terra repo ready"

# 2 — Download + republish
# =============================================================================
if (( NVR_MODE )); then
    emit_dnf_urls prime-run
    nvr_done
fi

info "Downloading prime-run..."
dnf download -q --arch x86_64 --arch noarch --destdir /output prime-run
[[ -n "$(find /output -name 'prime-run-*.rpm' -print -quit)" ]] \
    || die "prime-run RPM not downloaded"

for f in /output/prime-run-*.rpm; do
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean" || true
done
ok "RPM ready:"
ls -lh /output/*.rpm
