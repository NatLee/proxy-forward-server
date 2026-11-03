#!/bin/sh
# Starts OpenVPN, after removing the interface a previous run may have left behind.
#
# A normal tun/tap interface disappears together with OpenVPN. But when OpenVPN
# uses the kernel's data channel offload (DCO) and gets killed hard (SIGKILL,
# OOM), its interface stays in the shared network of the netns container. The
# next OpenVPN then opens tun1 while the routes still point at the dead tun0,
# and the proxy stops working. Removing the leftover first avoids that.
set -eu
conf=/etc/openvpn/client.conf # docker-compose.yml mounts the .ovpn here

# Which interface OpenVPN uses comes from the `dev` line of the config:
# "tun" / "tap" mean the next free tunN / tapN, anything else is the exact name.
dev=$(awk '$1 == "dev" { print $2; exit }' "$conf" 2>/dev/null || true)
case "$dev" in
  "") pattern='' ;;
  tun | tap) pattern="^${dev}[0-9]+\$" ;;
  *) pattern="^${dev}\$" ;;
esac

if [ -n "$pattern" ]; then
  for name in $(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E "$pattern" || true); do
    echo "removing leftover network interface $name from a previous OpenVPN run"
    ip link delete "$name"
  done
fi
exec openvpn --config "$conf" "$@"
