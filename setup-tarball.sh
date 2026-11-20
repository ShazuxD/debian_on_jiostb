#!/bin/bash
# Usage: sudo ./setup-tarball.sh [config.txt]
set -eu -o pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
CONF=$(readlink -f "${1:-$HERE/config.txt}")
[ -f "$CONF" ] || die "config file not found: $CONF"
cd "$HERE"
# shellcheck disable=SC1090
. "$CONF"

: "${SUITE:=trixie}" "${MIRROR:=http://deb.debian.org/debian}" "${EXTRA_PKGS:=}"
: "${HOSTNAME_:=jiobox}" "${ROOT_PW:=}" "${SSH_PORT:=2222}" "${SSH_PUBKEY:=}" "${SSH_ROOT_LOGIN:=yes}"
: "${LOCALE:=en_US.UTF-8}" "${TIMEZONE:=Etc/UTC}"
: "${STATIC_IP:=192.168.1.250/24}" "${GATEWAY:=192.168.1.1}" "${DNS:=1.1.1.1 8.8.8.8}"
: "${WIFI_SSID:=}" "${WIFI_PSK:=}" "${WIFI_COUNTRY:=00}"
: "${MODULES_DIR:=}" "${MODLIST:=}" "${FIRMWARE_DIR:=}" "${KERNEL_VERSION:=}"
: "${OUTPUT:=debian-arm64.tar.gz}" "${WORKDIR:=./rootfs-build}"

[ "$(id -u)" = 0 ] || die "run as root (sudo ./setup-tarball.sh)"
for t in debootstrap qemu-aarch64-static tar chroot; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
[ -n "$ROOT_PW" ] || [ -n "$SSH_PUBKEY" ] || die "set ROOT_PW or SSH_PUBKEY in config.txt, otherwise you cannot log in"

OUT=$(readlink -m "$WORKDIR")
case "$OUT" in /mnt/[a-z]/*) die "WORKDIR is on a Windows drive ($OUT); use the Linux filesystem, e.g. ~/build" ;; esac
[ -z "$(ls -A "$OUT" 2>/dev/null)" ] || die "$OUT is not empty - delete it first"

PKGS="systemd-sysv udev dbus kmod openssh-server openssh-client iproute2 iputils-ping iw rfkill wpasupplicant wireless-regdb python3 systemd-timesyncd ca-certificates nano less usbutils sudo locales tzdata curl wget git htop tmux rsync unzip zip bash-completion net-tools bind9-dnsutils ethtool lsof psmisc procps iptables $EXTRA_PKGS"
INCLUDE=$(echo $PKGS | tr ' ' ',')

detect_kver() {
  local f v
  f=$(find "$MODULES_DIR" -maxdepth 1 -name '*.ko' | head -n1)
  [ -n "$f" ] || return 0
  v=$(modinfo -F vermagic "$f" 2>/dev/null | awk '{print $1}' || true)
  if [ -z "$v" ] && command -v strings >/dev/null 2>&1; then
    v=$(strings "$f" | sed -n 's/^vermagic=//p' | head -n1 | awk '{print $1}')
  fi
  echo "$v"
}

# ---------------------------------------------------------------- 1. base system
echo "==> debootstrap $SUITE (arm64)"
mkdir -p "$OUT"
debootstrap --arch=arm64 --foreign --include="$INCLUDE" "$SUITE" "$OUT" "$MIRROR"
install -m755 "$(command -v qemu-aarch64-static)" "$OUT/usr/bin/"
chroot "$OUT" /debootstrap/debootstrap --second-stage

# ---------------------------------------------------------------- 2. configuration
echo "==> configuring"
echo "$HOSTNAME_" > "$OUT/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$HOSTNAME_" > "$OUT/etc/hosts"
: > "$OUT/etc/fstab"
: > "$OUT/etc/resolv.conf"
for d in $DNS; do echo "nameserver $d" >> "$OUT/etc/resolv.conf"; done

if [ -n "$ROOT_PW" ]; then
  echo "root:$ROOT_PW" | chroot "$OUT" chpasswd
fi
if [ -n "$SSH_PUBKEY" ]; then
  mkdir -p "$OUT/root/.ssh"
  echo "$SSH_PUBKEY" >> "$OUT/root/.ssh/authorized_keys"
  chmod 700 "$OUT/root/.ssh"; chmod 600 "$OUT/root/.ssh/authorized_keys"
fi

# Android kernel (CONFIG_ANDROID_PARANOID_NETWORK=y): only group 3003 may open IP sockets.
# _apt drops all supplementary groups, so aid_inet must be its PRIMARY group; services that keep
# their groups (timesyncd) only need membership; new normal users get it automatically.
chroot "$OUT" groupadd -f -g 3003 aid_inet
chroot "$OUT" usermod -g aid_inet _apt
chroot "$OUT" usermod -aG aid_inet systemd-timesync || echo "WARNING: systemd-timesync user not found"
sed -i '/^#\?EXTRA_GROUPS=/d;/^#\?ADD_EXTRA_GROUPS=/d' "$OUT/etc/adduser.conf"
printf 'ADD_EXTRA_GROUPS=1\nEXTRA_GROUPS="aid_inet"\n' >> "$OUT/etc/adduser.conf"

# ssh (00- prefix so it wins over other drop-ins; host keys are generated on first boot)
mkdir -p "$OUT/etc/ssh/sshd_config.d" "$OUT/etc/systemd/system/ssh.service.d"
cat > "$OUT/etc/ssh/sshd_config.d/00-jio.conf" <<EOF
Port $SSH_PORT
PermitRootLogin $SSH_ROOT_LOGIN
PasswordAuthentication yes
PubkeyAuthentication yes
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
cat > "$OUT/etc/systemd/system/ssh.service.d/hostkeys.conf" <<'EOF'
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
EOF

# networking (systemd-networkd): wired static or DHCP, Wi-Fi DHCP with a worse route metric
mkdir -p "$OUT/etc/systemd/network"
if [ "$STATIC_IP" = dhcp ]; then
  printf '[Match]\nName=eth*\n\n[Network]\nDHCP=yes\n\n[DHCP]\nRouteMetric=100\n' \
    > "$OUT/etc/systemd/network/10-eth.network"
else
  printf '[Match]\nName=eth*\n\n[Network]\nAddress=%s\nDNS=%s\n\n[Route]\nGateway=%s\nMetric=100\n' \
    "$STATIC_IP" "$DNS" "$GATEWAY" > "$OUT/etc/systemd/network/10-eth.network"
fi
printf '[Match]\nName=wlan*\n\n[Network]\nDHCP=yes\n\n[DHCP]\nRouteMetric=600\n' \
  > "$OUT/etc/systemd/network/20-wlan.network"

# Wi-Fi: wpa_supplicant config
mkdir -p "$OUT/etc/wpa_supplicant"
C="$OUT/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
printf 'ctrl_interface=/run/wpa_supplicant\nupdate_config=1\ncountry=%s\n' "$WIFI_COUNTRY" > "$C"
if [ -n "$WIFI_SSID" ]; then
  if [ -n "$WIFI_PSK" ]; then
    chroot "$OUT" wpa_passphrase "$WIFI_SSID" "$WIFI_PSK" | sed '/#psk=/d' >> "$C"
  else
    printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$WIFI_SSID" >> "$C"
  fi
fi
chmod 600 "$C"

# Wi-Fi: power the module through Amlogic /dev/wifi_power, then let udev bind the driver
cat > "$OUT/usr/local/sbin/wifi-up" <<'EOF'
#!/bin/sh
# WIFI_POWER_UP is _IO('m', 3) = 0x6d03 on /dev/wifi_power (Amlogic wifi_dt driver)
KVER=$(uname -r)
[ -d "/lib/modules/$KVER" ] && depmod -a "$KVER" 2>/dev/null
modprobe aml_sdio 2>/dev/null || true
if [ ! -c /dev/wifi_power ]; then
  echo "wifi-up: no /dev/wifi_power on this kernel"; exit 0
fi
python3 - <<'PY'
import fcntl, os
fd = os.open('/dev/wifi_power', os.O_RDWR)
fcntl.ioctl(fd, 0x6d03)
PY
sleep 1
udevadm trigger --subsystem-match=sdio --action=add 2>/dev/null || true
udevadm settle --timeout=10 2>/dev/null || true
for i in $(seq 1 15); do
  [ -d /sys/class/net/wlan0 ] && exit 0
  sleep 1
done
echo "wifi-up: wlan0 did not appear. SDIO ids:"
cat /sys/bus/sdio/devices/*/vendor /sys/bus/sdio/devices/*/device 2>/dev/null
exit 0
EOF
chmod 755 "$OUT/usr/local/sbin/wifi-up"

cat > "$OUT/etc/systemd/system/wifi-up.service" <<'EOF'
[Unit]
Description=Power up Wi-Fi module (Amlogic wifi_power)
After=systemd-udevd.service
Before=network-pre.target systemd-networkd.service wpa_supplicant@wlan0.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wifi-up

[Install]
WantedBy=multi-user.target
EOF

chroot "$OUT" systemctl disable wpa_supplicant.service 2>/dev/null || true
for u in ssh systemd-networkd systemd-timesyncd wifi-up.service wpa_supplicant@wlan0.service; do
  chroot "$OUT" systemctl enable "$u" || echo "WARNING: could not enable $u"
done
chroot "$OUT" systemctl set-default multi-user.target || true

# locale + timezone
if grep -q "^# *$LOCALE UTF-8" "$OUT/etc/locale.gen" 2>/dev/null; then
  sed -i "s/^# *$LOCALE UTF-8/$LOCALE UTF-8/" "$OUT/etc/locale.gen"
else
  echo "$LOCALE UTF-8" >> "$OUT/etc/locale.gen"
fi
chroot "$OUT" locale-gen
echo "LANG=$LOCALE" > "$OUT/etc/default/locale"
if [ -e "$OUT/usr/share/zoneinfo/$TIMEZONE" ]; then
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$OUT/etc/localtime"
  echo "$TIMEZONE" > "$OUT/etc/timezone"
else
  echo "WARNING: unknown TIMEZONE '$TIMEZONE', left at UTC"
fi

# this kernel has no nf_tables: use the legacy iptables backend
for t in iptables ip6tables; do
  chroot "$OUT" update-alternatives --set "$t" "/usr/sbin/$t-legacy" || echo "WARNING: could not switch $t to legacy"
done

# helper: create a login user (password, sudo, network group via adduser.conf)
cat > "$OUT/usr/local/sbin/mkuser" <<'EOF'
#!/bin/sh
# mkuser NAME - create a normal login user with sudo rights
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -n "${1:-}" ] || { echo "usage: mkuser <name>"; exit 1; }
adduser "$1" || exit 1
usermod -aG sudo "$1"
PORT=$(awk '/^Port/{print $2; exit}' /etc/ssh/sshd_config.d/*.conf 2>/dev/null)
echo
id "$1"
echo "switch now:  su - $1"
echo "ssh:         ssh -p ${PORT:-22} $1@<box ip>"
echo "when it works, turn off root ssh: set 'PermitRootLogin no' in /etc/ssh/sshd_config.d/00-jio.conf, then: systemctl restart ssh"
EOF
chmod 755 "$OUT/usr/local/sbin/mkuser"

# ---------------------------------------------------------------- 3. vendor modules + firmware
if [ -n "$MODULES_DIR" ]; then
  [ -d "$MODULES_DIR" ] || die "MODULES_DIR not found: $MODULES_DIR"
  KVER=${KERNEL_VERSION:-$(detect_kver)}
  [ -n "$KVER" ] || die "could not detect the kernel version; set KERNEL_VERSION in config.txt"
  echo "==> baking vendor modules for kernel $KVER"
  DEST="$OUT/lib/modules/$KVER"
  mkdir -p "$DEST"
  if [ -n "$MODLIST" ]; then
    for m in $MODLIST; do
      [ -f "$MODULES_DIR/$m.ko" ] || die "module not found: $MODULES_DIR/$m.ko"
      cp "$MODULES_DIR/$m.ko" "$DEST/"
    done
  else
    cp -a "$MODULES_DIR"/. "$DEST/"
  fi
  chroot "$OUT" depmod -a "$KVER" 2>/dev/null || true
else
  echo "WARNING: MODULES_DIR is empty - Wi-Fi will not work until you add the vendor modules"
fi
if [ -n "$FIRMWARE_DIR" ]; then
  [ -d "$FIRMWARE_DIR" ] || die "FIRMWARE_DIR not found: $FIRMWARE_DIR"
  mkdir -p "$OUT/lib/firmware"
  cp -a "$FIRMWARE_DIR"/. "$OUT/lib/firmware/"
fi

# ---------------------------------------------------------------- 4. clean up and pack
echo "==> packing $OUTPUT"
chroot "$OUT" apt-get clean || true
rm -f "$OUT"/etc/ssh/ssh_host_*                 # regenerated on first boot
: > "$OUT/etc/machine-id"                       # created on first boot
mkdir -p "$OUT/var/lib/dbus"; ln -sf /etc/machine-id "$OUT/var/lib/dbus/machine-id"
rm -f "$OUT/usr/bin/qemu-aarch64-static"
tar -C "$OUT" --numeric-owner -czpf "$OUTPUT" .
echo "done: $HERE/$OUTPUT"
echo "Next: copy it to the box and extract it as root into /data/debian"
