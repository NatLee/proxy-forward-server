#!/bin/sh
# End-to-end test without a real VPN or a real server.
#
# Starts a throwaway "remote host" (an OpenVPN server that also runs sshd and
# is reachable only through the VPN), points the real docker-compose.yml at
# it, and checks that a program on that host can use the proxy through
# 127.0.0.1:2080. Your own .env, keys/ and openvpn/ are not used or changed.
#
# Usage:  sh tests/e2e/run.sh
# Needs:  Docker with Compose v2, /dev/net/tun (Linux, or Docker Desktop),
#         and internet access (it fetches https://example.com through the proxy).
set -eu
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: pass container paths through untouched

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work="$here/.work"

# Docker needs Windows-style paths when this runs in Git Bash.
hostpath() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }

compose() {
  docker compose -p proxy-forward-e2e --project-directory "$(hostpath "$root")" \
    -f "$(hostpath "$root")/docker-compose.yml" -f "$(hostpath "$here")/compose.e2e.yml" \
    --env-file "$(hostpath "$work")/.env" "$@"
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- container logs (last 30 lines each)"
    compose logs --no-color --tail 30 2>/dev/null || true
  fi
  compose down -v -t 2 >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}

rm -rf "$work"
mkdir -p "$work"
cat > "$work/.env" <<'EOF'
REMOTE_HOST=10.8.0.1
REMOTE_USER=ubuntu
REMOTE_PORT=2080
SSH_KEY_PATH=./tests/e2e/.work/keys/key-to-aws.pem
OVPN_CONFIG_PATH=./tests/e2e/.work/openvpn/client.ovpn
PROXY_PORT=1080
EOF
trap cleanup EXIT INT TERM

echo "--- generating a test CA, VPN certs and an SSH key"
docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "$(hostpath "$work"):/out" -v "$(hostpath "$here"):/e2e:ro" \
  alpine:3.22 sh /e2e/gen.sh

echo "--- starting the stack"
compose up -d --build --quiet-pull 2>&1 | tail -n 5

echo "--- waiting for the reverse tunnel (up to 150 seconds)"
deadline=$(($(date +%s) + 150))
until compose exec -T vpnserver curl -fsS -m 5 -o /dev/null \
  -x socks5h://127.0.0.1:2080 https://example.com/ >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "the proxy never answered on the remote host's 127.0.0.1:2080"
    exit 1
  fi
  sleep 3
done

failed=0
check() {
  name=$1
  shift
  if out=$("$@" 2>&1); then
    echo "ok   $name"
  else
    echo "FAIL $name"
    printf '%s\n' "$out" | tail -n 5
    failed=1
  fi
}
on_remote() { compose exec -T vpnserver "$@"; }

ssh_came_through_vpn() {
  compose logs --no-color vpnserver | grep -q "Accepted publickey for ubuntu from 10.8.0.2"
}
default_route_not_on_vpn() {
  routes=$(compose exec -T openvpn ip route)
  echo "$routes"
  echo "$routes" | grep -q "^default .* dev eth0" && ! echo "$routes" | grep -q "^0.0.0.0/1"
}
remote_port_on_loopback_only() {
  listeners=$(on_remote netstat -tln | grep ":2080 ")
  echo "$listeners"
  [ -n "$listeners" ] && ! echo "$listeners" | grep -q -v -E "127\.0\.0\.1:2080|::1:2080"
}

check "SOCKS5 (socks5h://) from the remote host" \
  on_remote curl -fsS -m 20 -o /dev/null -x socks5h://127.0.0.1:2080 https://example.com/
check "HTTP proxy, HTTPS site (CONNECT)" \
  on_remote curl -fsS -m 20 -o /dev/null -x http://127.0.0.1:2080 https://example.com/
check "HTTP proxy, plain HTTP site" \
  on_remote curl -fsS -m 20 -o /dev/null -x http://127.0.0.1:2080 http://example.com/
check "SSH came in through the VPN (from 10.8.0.2)" ssh_came_through_vpn
check "route-nopull kept the default route off the VPN" default_route_not_on_vpn
check "remote port 2080 listens on loopback only" remote_port_on_loopback_only

if [ "$failed" -ne 0 ]; then
  echo "--- end-to-end test FAILED"
  exit 1
fi
echo "--- end-to-end test passed"
