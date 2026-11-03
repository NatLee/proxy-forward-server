#!/bin/sh
# Starts OpenVPN, after removing tun/tap interfaces left behind by a previous run.
#
# A normal tun interface disappears together with OpenVPN. But when OpenVPN uses
# the kernel's data channel offload (DCO) and gets killed hard (SIGKILL, OOM),
# its interface stays in the shared network of the netns container. The next
# OpenVPN then opens tun1 while the routes still point at the dead tun0, and the
# proxy stops working. Removing the leftovers first avoids that.
set -eu
leftovers=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(tun|tap)[0-9]+$' || true)
for dev in $leftovers; do
  echo "removing leftover network interface $dev from a previous OpenVPN run"
  ip link delete "$dev"
done
exec openvpn --config /etc/openvpn/client.conf "$@"
