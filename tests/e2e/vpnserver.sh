#!/bin/sh
# The test "remote host": an OpenVPN server that also runs sshd.
# sshd listens only on the server's VPN address, so the tunnel can reach it
# only through the VPN, just like a server inside a private network.
# Settings come from run.sh: E2E_VPN_NET (e.g. 10.8.0) and E2E_SSH_USER.
set -eu
: "${E2E_VPN_NET:?set by run.sh}" "${E2E_SSH_USER:?set by run.sh}"
server_ip="$E2E_VPN_NET.1" # OpenVPN's `server` directive gives the server .1
user=$E2E_SSH_USER

apk add --no-cache openssh-server curl >/dev/null # OpenVPN is already in the image
ssh-keygen -A >/dev/null

# The SSH user; '*' = no password, key login only. Idempotent, so the
# container can be restarted.
id "$user" >/dev/null 2>&1 || adduser -D "$user"
echo "$user:*" | chpasswd -e
install -d -m 700 -o "$user" -g "$user" "/home/$user/.ssh"
install -m 600 -o "$user" -g "$user" /srv/server/authorized_keys "/home/$user/.ssh/authorized_keys"
# Alpine ships with AllowTcpForwarding no; most servers (Ubuntu, Debian) allow it.
sed -i 's/^AllowTcpForwarding .*/AllowTcpForwarding yes/' /etc/ssh/sshd_config

openvpn --config /srv/server/server.conf --daemon --log /tmp/openvpn.log
for _ in $(seq 1 30); do
  ip addr show tun0 2>/dev/null | grep -q "$server_ip" && break
  sleep 1
done
exec /usr/sbin/sshd -D -e -o ListenAddress="$server_ip"
