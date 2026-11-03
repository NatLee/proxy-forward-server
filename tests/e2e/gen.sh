#!/bin/sh
# Runs in the `gen` service of compose.e2e.yml (built from vpn/Dockerfile) and
# writes throwaway test material to /out:
#   server/   CA + server cert/key and server.conf for the test OpenVPN server,
#             plus authorized_keys for the test SSH user
#   openvpn/  client.ovpn, written the way the README recommends
#   keys/     the SSH key pair the tunnel uses
# Nothing here is a real credential; run.sh deletes it all afterwards.
# The VPN subnet comes from run.sh (E2E_VPN_NET, e.g. 10.8.0 for 10.8.0.0/24).
set -eu
: "${E2E_VPN_NET:?set by run.sh}"
apk add --no-cache easy-rsa openssh-keygen >/dev/null

out=/out
mkdir -p "$out/pki-work" "$out/server" "$out/keys" "$out/openvpn"
cd "$out/pki-work"
export EASYRSA_BATCH=1 EASYRSA_REQ_CN=proxy-forward-e2e-ca
for step in init-pki "build-ca nopass" "build-server-full server nopass" "build-client-full client nopass"; do
  # shellcheck disable=SC2086
  /usr/share/easy-rsa/easyrsa $step >/dev/null 2>&1
done
cp pki/ca.crt pki/issued/server.crt pki/private/server.key "$out/server/"

cat > "$out/server/server.conf" <<CONF
port 1194
proto udp
dev tun
topology subnet
server ${E2E_VPN_NET}.0 255.255.255.0
ca /srv/server/ca.crt
cert /srv/server/server.crt
key /srv/server/server.key
dh none
keepalive 10 60
# Act like a VPN that wants all of the client's traffic,
# so the test proves that route-nopull in client.ovpn keeps it out.
push "redirect-gateway def1"
verb 3
CONF

{
  cat <<CONF
client
dev tun
proto udp
remote vpnserver 1194
nobind
persist-key
persist-tun
remote-cert-tls server
verb 3
# Same advice as the README: ignore the routes the server pushes,
# send only the VPN subnet through the tunnel.
route-nopull
route ${E2E_VPN_NET}.0 255.255.255.0 vpn_gateway
CONF
  echo "<ca>"; cat pki/ca.crt; echo "</ca>"
  echo "<cert>"; sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' pki/issued/client.crt; echo "</cert>"
  echo "<key>"; cat pki/private/client.key; echo "</key>"
} > "$out/openvpn/client.ovpn"

ssh-keygen -q -t ed25519 -f "$out/keys/key-to-aws.pem" -N "" -C proxy-forward-e2e
cp "$out/keys/key-to-aws.pem.pub" "$out/server/authorized_keys"

rm -rf "$out/pki-work"
# Hand the files back to the user who started the test, so run.sh can delete them.
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$out" 2>/dev/null || true
