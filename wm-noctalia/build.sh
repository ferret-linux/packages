#!/bin/bash
# =============================================================================
#  wm-noctalia/build.sh
# =============================================================================
set -euo pipefail

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

rm -rf /root
mkdir -p /root/

# 1 — Install dnf5-plugins & enable COPRs
# =============================================================================
info "Installing dnf5-plugins..."
dnf install -y dnf5-plugins --setopt=install_weak_deps=False -q

info "Enabling COPRs..."
dnf copr enable -y yalter/niri
dnf copr enable -y lionheartp/Hyprland

info "Adding Terra repo..."
dnf install -y --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
    terra-release -q
dnf reinstall -y terra-release -q
dnf makecache --refresh
ok "Terra repo added"

# 2 — Download all packages
# =============================================================================
info "Downloading packages..."
dnf download niri mangowm \
    qt5ct qt6ct \
    cliphist nwg-look xcur2png \
    --destdir /output \
    --arch x86_64 --arch noarch \
    -q

# Strip epoch prefix (e.g. mangowm-0:0.23.4-1.fc43.x86_64.rpm → mangowm-0.23.4-1.fc43.x86_64.rpm)
for f in /output/*.rpm; do
    [[ -f "$f" ]] || continue
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

ok "All RPMs ready:"
ls /output/*.rpm