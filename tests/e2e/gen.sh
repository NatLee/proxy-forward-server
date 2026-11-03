#!/bin/sh
# Runs in the `gen` service of compose.e2e.yml (built from vpn/Dockerfile) and
# writes throwaway test material to /out:
#   server/   CA + server cert/key and server.conf for the test OpenVPN server,
#             plus authorized_keys for the test SSH user
#   E2E_OVPN_FILE  the client .ovpn, written the way the README recommends
#   E2E_KEY_FILE   the SSH key pair the tunnel uses
# (both relative to /out, laid out like .env.example; run.sh passes the names)
# Nothing here is a real credential; run.sh deletes it all afterwards.
# The VPN subnet and the test server's host name come from run.sh / compose.e2e.yml
# (E2E_VPN_NET, e.g. 10.8.0 for 10.8.0.0/24, and E2E_VPN_SERVER).
set -eu
: "${E2E_VPN_NET:?set by run.sh}" "${E2E_VPN_SERVER:?set by compose.e2e.yml}"
: "${E2E_OVPN_FILE:?set by run.sh}" "${E2E_KEY_FILE:?set by run.sh}"
vpn_port=1194 # OpenVPN's registered port; used by both configs below
apk add --no-cache easy-rsa openssh-keygen >/dev/null

out=/out
mkdir -p "$out/pki-work" "$out/server" "$out/$(dirname "$E2E_KEY_FILE")" "$out/$(dirname "$E2E_OVPN_FILE")"
cd "$out/pki-work"
export EASYRSA_BATCH=1 EASYRSA_REQ_CN=proxy-forward-e2e-ca
for step in init-pki "build-ca nopass" "build-server-full server nopass" "build-client-full client nopass"; do
  # shellcheck disable=SC2086
  /usr/share/easy-rsa/easyrsa $step >/dev/null 2>&1
done
cp pki/ca.crt pki/issued/server.crt pki/private/server.key "$out/server/"

cat > "$out/server/server.conf" <<CONF
port $vpn_port
proto udp
dev tun
topology subnet
server ${E2E_VPN_NET}.0 255.255.255.0
# Paths are relative: vpnserver.sh starts OpenVPN with --cd in this folder.
ca ca.crt
cert server.crt
key server.key
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
remote $E2E_VPN_SERVER $vpn_port
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
} > "$out/$E2E_OVPN_FILE"

ssh-keygen -q -t ed25519 -f "$out/$E2E_KEY_FILE" -N "" -C proxy-forward-e2e
cp "$out/$E2E_KEY_FILE.pub" "$out/server/authorized_keys"

rm -rf "$out/pki-work"
# Hand the files back to the user who started the test, so run.sh can delete them.
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$out" 2>/dev/null || true
