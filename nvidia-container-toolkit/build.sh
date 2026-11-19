#!/bin/bash
# =============================================================================
#  nvidia-container-toolkit/build.sh
#
#  Republish NVIDIA's official Container Toolkit RPMs (plus their dependency
#  closure) into Ferret's repo, and build an SELinux policy package from
#  NVIDIA's own dgx-selinux sources. No COPRs, no Terra.
#
#  The upstream package ships `nvidia-cdi-refresh.{service,path}` itself, so
#  there is no longer any need for a hand-rolled CDI service package.
# =============================================================================
set -euo pipefail

info() { echo "[•] $*"; }
ok()   { echo "[✓] $*"; }
die()  { echo "[✗] $*" >&2; exit 1; }

rm -rf /root
mkdir -p /root/

WORKDIR=/tmp/nvidia-container-toolkit-build
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
mkdir -p /output

# 1 — Build dependencies
# =============================================================================
info "Installing build dependencies..."
dnf install -y --setopt=install_weak_deps=False -q \
    curl rpm-build dnf-plugins-core dnf5-plugins
ok "Dependencies installed"

# 2 — Official NVIDIA Container Toolkit repo (build-time only)
# =============================================================================
info "Adding NVIDIA Container Toolkit repository..."
# Import the key up front so the repo's repo_gpgcheck=1 doesn't prompt
# interactively during makecache/download in CI.
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -o "$WORKDIR/nvidia.gpg"
rpm --import "$WORKDIR/nvidia.gpg"
curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
    https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
dnf -y -q makecache
ok "NVIDIA repo ready"

# 3 — Download official RPMs + full runtime dependency closure
# =============================================================================
info "Downloading official NVIDIA RPMs..."
dnf -y -q download --arch x86_64 --destdir /output \
    nvidia-container-toolkit \
    nvidia-container-toolkit-base \
    libnvidia-container-tools \
    libnvidia-container1

for rpm in nvidia-container-toolkit nvidia-container-toolkit-base \
           libnvidia-container-tools libnvidia-container1; do
    [[ -n "$(find /output -name "${rpm}-[0-9]*.rpm" -print -quit)" ]] \
        || die "${rpm} RPM not downloaded"
done
ok "Downloaded 4 official RPMs"

VERSION="$(rpm -qp /output/nvidia-container-toolkit-[0-9]*.rpm \
    --queryformat '%{VERSION}' | head -1)"
[[ -n "$VERSION" ]] || die "Could not determine toolkit version"
ok "Version: $VERSION"

# 4 — SELinux policy from NVIDIA's official dgx-selinux project
# =============================================================================
info "Fetching NVIDIA dgx-selinux policy..."
POLICY="$WORKDIR/nvidia-container.pp"
curl -fsSL -o "$POLICY" \
    https://raw.githubusercontent.com/NVIDIA/dgx-selinux/master/bin/RHEL9/nvidia-container.pp
curl -fsSL -o "$WORKDIR/LICENSE-dgx-selinux" \
    https://raw.githubusercontent.com/NVIDIA/dgx-selinux/master/LICENSE
curl -fsSL -o "$WORKDIR/README-dgx-selinux.md" \
    https://raw.githubusercontent.com/NVIDIA/dgx-selinux/master/README.md
[[ -s "$POLICY" ]] || die "dgx-selinux policy download failed"

info "Building nvidia-container-toolkit-selinux..."
RPMBUILD="$WORKDIR/rpmbuild"
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp "$POLICY" "$RPMBUILD/SOURCES/nvidia-container.pp"

cat > "$RPMBUILD/SPECS/nvidia-container-toolkit-selinux.spec" <<SPEC
Name:           nvidia-container-toolkit-selinux
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        NVIDIA Container Toolkit SELinux Policy
License:        MIT
URL:            https://github.com/NVIDIA/nvidia-container-toolkit
BuildArch:      noarch
Source0:        nvidia-container.pp
Source1:        LICENSE-dgx-selinux
Source2:        README-dgx-selinux.md

# Upstream RPMs carry a plain "-1" release with no dist tag.
Requires:       nvidia-container-toolkit = %{version}-1
Requires:       (container-selinux >= 2.213 if selinux-policy-targeted)
Requires:       policycoreutils
Requires:       selinux-policy

%description
SELinux policy to enable the NVIDIA Container Toolkit to use the GPU.
Built from NVIDIA's official dgx-selinux sources. Enables the
container_use_xserver_devices boolean on install and restores it on removal,
and provides the nvidia_container_t type for restrictive GPU containers.

%install
mkdir -p %{buildroot}%{_datadir}/selinux/packages/targeted
mkdir -p %{buildroot}%{_docdir}/%{name}
mkdir -p %{buildroot}%{_licensedir}/%{name}
install -m 0644 %{SOURCE0} %{buildroot}%{_datadir}/selinux/packages/targeted/nvidia-container.pp
install -m 0644 %{SOURCE2} %{buildroot}%{_docdir}/%{name}/dgx-selinux-README.md
install -m 0644 %{SOURCE1} %{buildroot}%{_licensedir}/%{name}/LICENSE-dgx-selinux

%post
if [ \$1 -eq 1 ]; then
    if grep -q '0 0' /sys/fs/selinux/booleans/container_use_xserver_devices 2>/dev/null; then
        install -m 0755 -vd /var/lib/rpm-state/nvidia-container-toolkit/
        touch /var/lib/rpm-state/nvidia-container-toolkit/managed-selinux-bool-xserver
        setsebool -P container_use_xserver_devices 1 || :
    fi
fi

if [ -e /etc/selinux/config ]; then
    . /etc/selinux/config
fi
_policytype=\${SELINUXTYPE:-targeted}
if [ "\${_policytype}" = targeted ]; then
    rm -rf /var/lib/selinux/\${_policytype}/active/modules/400/extra_varrun || :
    semodule -n -s \${_policytype} -X 200 -i %{_datadir}/selinux/packages/targeted/nvidia-container.pp || :
    selinuxenabled && load_policy || :
    /usr/libexec/selinux/varrun-convert.sh \${_policytype} || :
fi

%postun
if [ \$1 -eq 0 ]; then
    if [ -f /var/lib/rpm-state/nvidia-container-toolkit/managed-selinux-bool-xserver ]; then
        setsebool -P container_use_xserver_devices 0 || :
        rm -f /var/lib/rpm-state/nvidia-container-toolkit/managed-selinux-bool-xserver
    fi
    if [ -e /etc/selinux/config ]; then
        . /etc/selinux/config
    fi
    _policytype=\${SELINUXTYPE:-targeted}
    if [ "\${_policytype}" = targeted ]; then
        rm -rf /var/lib/selinux/\${_policytype}/active/modules/400/extra_varrun || :
        semodule -n -X 200 -s \${_policytype} -r nvidia-container &>/dev/null || :
        selinuxenabled && load_policy || :
        /usr/libexec/selinux/varrun-convert.sh \${_policytype} || :
    fi
fi

%files
%{_datadir}/selinux/packages/targeted/nvidia-container.pp
%{_docdir}/%{name}/dgx-selinux-README.md
%{_licensedir}/%{name}/LICENSE-dgx-selinux

%changelog
* %(date '+%a %b %d %Y') Ferret Linux <ferret-linux> - %{version}-1
- Package NVIDIA dgx-selinux policy for the Container Toolkit
SPEC

for src in LICENSE-dgx-selinux README-dgx-selinux.md; do
    cp "$WORKDIR/$src" "$RPMBUILD/SOURCES/$src"
done

rpmbuild \
    --define "_topdir $RPMBUILD" \
    -bb "$RPMBUILD/SPECS/nvidia-container-toolkit-selinux.spec" 2>&1 \
    | grep -vE '^(warning: )?(%source_date_epoch_from_changelog|Wrote:)' || true

RPM_FILE="$(find "$RPMBUILD/RPMS" -name 'nvidia-container-toolkit-selinux-*.rpm' -print -quit)"
[[ -f "$RPM_FILE" ]] || die "SELinux RPM not built"
cp "$RPM_FILE" /output/
ok "SELinux RPM built"

# 5 — Verify + report
# =============================================================================
COUNT="$(find /output -maxdepth 1 -name '*.rpm' | wc -l)"
[[ "$COUNT" -eq 5 ]] || die "Expected 5 RPMs, got $COUNT"
info "Final output:"
for f in /output/*.rpm; do
    rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$f" 2>/dev/null
done
ok "All 5 RPMs ready in /output/"
