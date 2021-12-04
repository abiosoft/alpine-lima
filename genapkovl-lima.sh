#!/bin/sh -e

HOSTNAME="$1"
if [ -z "$HOSTNAME" ]; then
    echo "usage: $0 hostname"
    exit 1
fi

cleanup() {
    rm -rf "$tmp"
}

makefile() {
    OWNER="$1"
    PERMS="$2"
    FILENAME="$3"
    cat >"$FILENAME"
    chown "$OWNER" "$FILENAME"
    chmod "$PERMS" "$FILENAME"
}

rc_add() {
    mkdir -p "$tmp"/etc/runlevels/"$2"
    ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
}

tmp="$(mktemp -d)"
trap cleanup EXIT

mkdir -p "$tmp"/etc
makefile root:root 0644 "$tmp"/etc/hostname <<EOF
$HOSTNAME
EOF

mkdir -p "$tmp"/etc/network
makefile root:root 0644 "$tmp"/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

mkdir -p "$tmp"/etc/apk
makefile root:root 0644 "$tmp"/etc/apk/world <<EOF
alpine-base
openssh-server-pam
EOF

rc_add devfs sysinit
rc_add dmesg sysinit

# cloud-init / lima-init require udev instead (for /dev/disk/...)
if [ "${LIMA_INSTALL_CLOUD_INIT}" != "true" -a "${LIMA_INSTALL_LIMA_INIT}" != "true" ]; then
    rc_add mdev sysinit
    rc_add hwdrivers sysinit
fi

rc_add modloop sysinit

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

rc_add networking default

rc_add sshd default

# lima-overlay must run with the boot filesystem, so has to run before
# cloud-init or lima-init because the boot script will remap /etc and
# /var/lib to the data volume.

mkdir -p "${tmp}/etc/init.d/"
makefile root:root 0755 "$tmp/etc/init.d/lima-overlay" <<EOF
#!/sbin/openrc-run

depend() {
  after localmount
  before cloud-init-local lima-init-local sshd
  provide lima-overlay
}

start() {
  sed -i 's/#UsePAM no/UsePAM yes/g' /etc/ssh/sshd_config

  echo "BUILD_ID=\"${LIMA_BUILD_ID}\"" >> /etc/os-release
  echo "VARIANT_ID=\"${LIMA_VARIANT_ID}\"" >> /etc/os-release

  eend 0
}
EOF

rc_add lima-overlay default

mkdir -p "$tmp"/etc/pam.d
cp /home/build/sshd.pam "${tmp}/etc/pam.d/sshd"

if [ "${LIMA_INSTALL_LIMA_INIT}" == "true" ]; then
    rc_add lima-init default
    rc_add lima-init-local default

    mkdir -p "${tmp}/etc/init.d/"
    cp /home/build/lima-init.openrc "${tmp}/etc/init.d/lima-init"
    cp /home/build/lima-init-local.openrc "${tmp}/etc/init.d/lima-init-local"

    mkdir -p "${tmp}/usr/bin/"
    cp /home/build/lima-init.sh "${tmp}/usr/bin/lima-init"
    cp /home/build/lima-network.awk "${tmp}/usr/bin/lima-network.awk"

    echo e2fsprogs >>"$tmp"/etc/apk/world
    echo lsblk >>"$tmp"/etc/apk/world
    echo sfdisk >>"$tmp"/etc/apk/world
    echo shadow >>"$tmp"/etc/apk/world
    echo sudo >>"$tmp"/etc/apk/world
    echo udev >>"$tmp"/etc/apk/world

    rc_add udev sysinit
    rc_add udev-postmount default
    rc_add udev-trigger sysinit

    rc_add machine-id sysinit
fi

if [ "${LIMA_INSTALL_CLOUD_INIT}" == "true" ]; then
    echo cloud-init >>"$tmp"/etc/apk/world

    rc_add cloud-init-local boot
    rc_add cloud-config default
    rc_add cloud-final default
    rc_add cloud-init default

    rc_add udev sysinit
    rc_add udev-postmount default
    rc_add udev-trigger sysinit

    mkdir -p "${tmp}/etc/cloud/cloud.cfg.d/"
    makefile root:root 0644 "$tmp/etc/cloud/cloud.cfg.d/10_lima.cfg" <<EOF
datasource_list: [ NoCloud, None ]
EOF
fi

if [ "${LIMA_INSTALL_DOCKER}" == "true" ]; then
    echo libseccomp >>"$tmp"/etc/apk/world
    echo runc >>"$tmp"/etc/apk/world
    echo containerd >>"$tmp"/etc/apk/world
    echo tini-static >>"$tmp"/etc/apk/world
    echo device-mapper-libs >>"$tmp"/etc/apk/world
    echo docker-engine >>"$tmp"/etc/apk/world
    echo docker-openrc >>"$tmp"/etc/apk/world
    echo docker-cli >>"$tmp"/etc/apk/world
    echo docker >>"$tmp"/etc/apk/world
fi

if [ "${LIMA_INSTALL_PODMAN}" == "true" ]; then
    echo libseccomp >>"$tmp"/etc/apk/world
    echo runc >>"$tmp"/etc/apk/world
    echo conmon >>"$tmp"/etc/apk/world
    echo cni-plugins >>"$tmp"/etc/apk/world
    echo slirp4netns >>"$tmp"/etc/apk/world
    echo fuse-overlayfs >>"$tmp"/etc/apk/world
    echo podman >>"$tmp"/etc/apk/world
fi

if [ "${LIMA_INSTALL_BINFMT_MISC}" == "true" ]; then
    echo "qemu-aarch64" >>"$tmp"/etc/apk/world
    echo "qemu-x86_64" >>"$tmp"/etc/apk/world
    echo "qemu-arm" >>"$tmp"/etc/apk/world
    echo "qemu-i386" >>"$tmp"/etc/apk/world
    echo "qemu-ppc64le" >>"$tmp"/etc/apk/world
    echo "qemu-riscv64" >>"$tmp"/etc/apk/world
    echo "qemu-riscv64" >>"$tmp"/etc/apk/world
    echo "qemu-s390x" >>"$tmp"/etc/apk/world

    mkdir -p "${tmp}/etc/init.d/"
    APKBUILD=/home/build/aports/community/qemu-openrc/APKBUILD
    PKGVER=$(awk '/^pkgver=/ {split($1, a, "="); print a[2]}' ${APKBUILD})
    URL=$(awk '/^url=/ {split($1, a, "="); print a[2]}' ${APKBUILD} | tr -d '"' | sed 's/github/raw.githubusercontent/')
    wget "${URL}/v${PKGVER}/qemu-binfmt.initd" -O "${tmp}/etc/init.d/qemu-binfmt"
    chmod +x "${tmp}/etc/init.d/qemu-binfmt"

    rc_add qemu-binfmt default
fi

if [ "${LIMA_INSTALL_CA_CERTIFICATES}" == "true" ]; then
    echo "ca-certificates" >>"$tmp"/etc/apk/world
fi

if [ "${LIMA_INSTALL_K3S}" == "true" ]; then
    echo "k3s" >>"$tmp"/etc/apk/world
    rc_add k3s default
fi

if [ "${LIMA_INSTALL_LOGROTATE}" == "true" ]; then
    echo "logrotate" >>"$tmp"/etc/apk/world
fi

if [ "${LIMA_INSTALL_IPTABLES}" == "true" ] || [ "${LIMA_INSTALL_NERDCTL}" == "true" ]; then
    echo "iptables ip6tables" >>"$tmp"/etc/apk/world
fi

if [ "${LIMA_INSTALL_NERDCTL}" == "true" ]; then
    mkdir -p "${tmp}/nerdctl"
    tar xz -C "${tmp}/nerdctl" -f /home/build/nerdctl.tar.gz

    mkdir -p "${tmp}/usr/local/bin/"
    for bin in buildctl buildkitd nerdctl; do
        cp "${tmp}/nerdctl/bin/${bin}" "${tmp}/usr/local/bin/${bin}"
        chmod u+s "${tmp}/usr/local/bin/${bin}"
    done
    mkdir -p "${tmp}/usr/local/libexec/cni"
    for plugin in bridge portmap firewall tuning isolation host-local; do
        cp "${tmp}/nerdctl/libexec/cni/${plugin}" "${tmp}/usr/local/libexec/cni/${plugin}"
    done
fi

if [ "${LIMA_INSTALL_SSHFS}" == "true" ]; then
    echo "sshfs" >>"$tmp"/etc/apk/world
fi

# binfmt
mkdir -p "${tmp}/usr/local/colima"
cp /home/build/binfmt.tar "${tmp}/usr/local/colima/binfmt.tar"

mkdir -p "${tmp}/etc"
mkdir -p "${tmp}/usr"

tar -c -C "$tmp" etc usr | gzip -9n >$HOSTNAME.apkovl.tar.gz
