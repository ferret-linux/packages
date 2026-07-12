#!/bin/bash
# =============================================================================
#  gui-cli/build.sh
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
dnf copr enable -y lilay/topgrade
dnf copr enable -y ublue-os/packages
dnf copr enable -y trixieua/morewaita-icon-theme
dnf config-manager addrepo -y --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo

sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc &&
echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\nautorefresh=1\ntype=rpm-md\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" | sudo tee /etc/yum.repos.d/vscode.repo > /dev/null

# 2 — Copr RPMs Download
# =============================================================================
info "Downloading packages from COPR..."
dnf download bazaar topgrade morewaita-icon-theme \
    --destdir /output \
    --arch x86_64 --arch noarch \
    -q

dnf copr disable -y lilay/topgrade
dnf copr disable -y ublue-os/packages

# 3 — Terra RPMs Download
# ==============================================================================
info "Adding Terra repo..."
dnf install -y --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
    terra-release -q
dnf reinstall -y terra-release -q
dnf makecache --refresh
ok "Terra repo added"

info "Downloading packages from Terra..."
dnf download \
    scx-scheds scx-tools brave-origin brave-keyring code starship heroic-games-launcher protonplus hack-nerd-fonts nerdfontssymbolsonly-nerd-fonts \
    ghostty ghostty-nautilus ghostty-zsh-completion ghostty-terminfo ghostty-shell-integration ghostty-bat-syntax ghostty-neovim ghostty-kio noctalia-greeter \
    --destdir /output \
    --arch x86_64 --arch noarch \
    -q

# 4 — Verity & Fix RPMs
# ==============================================================================

# Strip epoch prefix (e.g. eza-0:0.23.4-1.fc43.x86_64.rpm → eza-0.23.4-1.fc43.x86_64.rpm)
for f in /output/*.rpm; do
    [[ -f "$f" ]] || continue
    base=${f##*/}
    clean=${base//:/-}
    clean=${clean//^/-}
    [[ "$base" != "$clean" ]] && mv -- "$f" "/output/$clean"
done

ok "RPM ready:"
ls /output/*.rpm