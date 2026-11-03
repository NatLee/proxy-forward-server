#!/bin/sh
# The test "remote host": an OpenVPN server that also runs sshd.
# sshd listens only on the VPN address 10.8.0.1, so the tunnel can reach it
# only through the VPN, just like a server inside a private network.
set -eu
apk add --no-cache openvpn openssh-server curl >/dev/null
ssh-keygen -A >/dev/null

# The SSH user from .env (REMOTE_USER=ubuntu); '*' = no password, key login only.
adduser -D ubuntu
echo 'ubuntu:*' | chpasswd -e
install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
install -m 600 -o ubuntu -g ubuntu /srv/server/authorized_keys /home/ubuntu/.ssh/authorized_keys
# Alpine ships with AllowTcpForwarding no; most servers (Ubuntu, Debian) allow it.
sed -i 's/^AllowTcpForwarding .*/AllowTcpForwarding yes/' /etc/ssh/sshd_config

openvpn --config /srv/server/server.conf --daemon --log /tmp/openvpn.log
for _ in $(seq 1 30); do
  ip addr show tun0 2>/dev/null | grep -q 10.8.0.1 && break
  sleep 1
done
exec /usr/sbin/sshd -D -e -o ListenAddress=10.8.0.1
