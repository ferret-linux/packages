#!/bin/bash
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

info "Enabling ublue-os/packages COPR..."
dnf install -y -q dnf5-plugins
dnf copr enable -y ublue-os/packages -q

if (( NVR_MODE )); then
    emit_dnf_urls ublue-os-udev-rules oversteer-udev
    nvr_done
fi

info "Downloading ublue-os-udev-rules + oversteer-udev..."
dnf download --arch x86_64 --arch noarch \
    ublue-os-udev-rules \
    oversteer-udev \
    --destdir /output -q

for f in /output/*.rpm; do
    [[ -f "$f" ]] || continue
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

info "Showing downloaded files..."
ls -lh /output