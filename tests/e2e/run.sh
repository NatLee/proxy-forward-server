#!/bin/sh
# End-to-end test without a real VPN or a real server.
#
# Starts a throwaway "remote host" (an OpenVPN server that also runs sshd and
# is reachable only through the VPN), points the real docker-compose.yml at
# it, and checks that a program on that host can use the proxy through
# 127.0.0.1:2080. Then it checks the things that are easy to break:
#   - the proxy is loopback-only by default, and PROXY_BIND=0.0.0.0 opens it up
#   - the proxy comes back on its own after openvpn restarts, crashes or is
#     down for a while
#   - the openvpn container installs nothing at start-up
# Your own .env, keys/ and openvpn/ are not used or changed.
#
# Usage:  sh tests/e2e/run.sh
#         E2E_KEEP=1 sh tests/e2e/run.sh      leave the stack running afterwards
#         E2E_RESTART_DOCKER=1 sh tests/e2e/run.sh
#                                             also restart the Docker daemon (uses
#                                             sudo systemctl; CI only, never on your machine)
# Needs:  Docker with Compose v2, /dev/net/tun (Linux, or Docker Desktop),
#         and internet access (it fetches https://example.com through the proxy).
set -eu
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: pass container paths through untouched

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work="$here/.work"
probe_image=curlimages/curl:8.11.1
pinned_alpine=alpine:3.24.3

# Docker needs Windows-style paths when this runs in Git Bash.
hostpath() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }

compose() {
  docker compose -p proxy-forward-e2e --project-directory "$(hostpath "$root")" \
    -f "$(hostpath "$root")/docker-compose.yml" -f "$(hostpath "$here")/compose.e2e.yml" \
    --env-file "$(hostpath "$work")/.env" "$@"
}

cleanup() {
  status=$?
  if [ "${E2E_KEEP:-}" = 1 ]; then
    echo "--- E2E_KEEP=1: leaving the stack running (compose project proxy-forward-e2e)"
    exit "$status"
  fi
  if [ "$status" -ne 0 ]; then
    echo "--- container logs (last 30 lines each)"
    compose logs --no-color --tail 30 2>/dev/null || true
  fi
  compose down -v -t 2 >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}

write_env() { # $1: extra line for .env (may be empty)
  cat > "$work/.env" <<EOF
REMOTE_HOST=10.8.0.1
REMOTE_USER=ubuntu
REMOTE_PORT=2080
SSH_KEY_PATH=./tests/e2e/.work/keys/key-to-aws.pem
OVPN_CONFIG_PATH=./tests/e2e/.work/openvpn/client.ovpn
PROXY_PORT=1080
$1
EOF
}

rm -rf "$work"
mkdir -p "$work"
write_env ""
trap cleanup EXIT INT TERM

echo "--- generating a test CA, VPN certs and an SSH key"
docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "$(hostpath "$work"):/out" -v "$(hostpath "$here"):/e2e:ro" \
  "$pinned_alpine" sh /e2e/gen.sh
docker pull -q "$probe_image" >/dev/null

echo "--- starting the stack"
compose up -d --build --quiet-pull 2>&1 | tail -n 5

on_remote() { compose exec -T vpnserver "$@"; }
remote_request_ok() {
  on_remote curl -fsS -m 5 -o /dev/null -x socks5h://127.0.0.1:2080 https://example.com/ >/dev/null 2>&1
}
# Waits until a program on the remote host can use the proxy again.
# Prints how long it took; fails after $1 seconds.
wait_for_proxy() {
  start=$(date +%s)
  until remote_request_ok; do
    if [ $(($(date +%s) - start)) -ge "$1" ]; then
      echo "the remote host still can't use the proxy after $1 s"
      return 1
    fi
    sleep 1
  done
  echo "working again after $(($(date +%s) - start)) s"
}

echo "--- waiting for the reverse tunnel (up to 150 seconds)"
wait_for_proxy 150

failed=0
check() {
  name=$1
  shift
  if out=$("$@" 2>&1); then
    echo "ok   $name${out:+  ($(printf '%s' "$out" | tail -n 1))}"
  else
    echo "FAIL $name"
    printf '%s\n' "$out" | tail -n 5
    failed=1
  fi
}
not() { ! "$@"; }

# --- the basic path -----------------------------------------------------------

ssh_came_through_vpn() {
  compose logs --no-color vpnserver | grep -q "Accepted publickey for ubuntu from 10.8.0.2"
}
default_route_not_on_vpn() {
  routes=$(compose exec -T openvpn ip route)
  echo "$routes" | grep -q "^default .* dev eth0" && ! echo "$routes" | grep -q "^0.0.0.0/1"
}
remote_port_on_loopback_only() {
  listeners=$(on_remote netstat -tln | grep ":2080 ")
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

# --- who else can use the proxy ----------------------------------------------

# The shared namespace's address on the Docker network (the same for all three services).
shared_ip=$(compose exec -T tunnel ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
vpn_peer_can_use_proxy() {
  on_remote curl -fsS -m 8 -o /dev/null -x http://10.8.0.2:1080 http://example.com/
}
docker_neighbour_can_use_proxy() {
  docker run --rm --network proxy-forward-e2e_default "$probe_image" \
    -fsS -m 8 -o /dev/null -x "http://$shared_ip:1080" http://example.com/
}

check "default: a VPN peer can NOT use the proxy directly (10.8.0.2:1080)" not vpn_peer_can_use_proxy
check "default: another container on the Docker network can NOT use it ($shared_ip:1080)" \
  not docker_neighbour_can_use_proxy

# --- nothing gets installed when openvpn starts --------------------------------

openvpn_is_in_the_image() {
  image=$(docker inspect -f '{{.Config.Image}}' proxy-forward-e2e-openvpn)
  docker run --rm --network none --entrypoint openvpn "$image" --version | head -n 1
}
no_package_install_in_openvpn_logs() {
  ! compose logs --no-color openvpn | grep -E 'fetch https?://|OK: [0-9.]+ [KMG]i?B in [0-9]+ packages'
}
check "the openvpn image already contains OpenVPN (runs with no network)" openvpn_is_in_the_image
check "the openvpn container installed no packages at start-up" no_package_install_in_openvpn_logs

# --- the proxy comes back on its own after openvpn goes away --------------------

restarts() { docker inspect -f '{{.RestartCount}}' "$1"; }

restart_openvpn_and_wait() {
  docker restart proxy-forward-e2e-openvpn >/dev/null
  wait_for_proxy 30
}
crash_openvpn_and_wait() {
  before=$(restarts proxy-forward-e2e-openvpn)
  pid=$(docker inspect -f '{{.State.Pid}}' proxy-forward-e2e-openvpn)
  # SIGKILL from outside, like an OOM kill; the restart policy brings it back.
  docker run --rm --pid=host "$pinned_alpine" kill -9 "$pid"
  wait_for_proxy 30 || return 1
  [ "$(restarts proxy-forward-e2e-openvpn)" -gt "$before" ]
}
long_vpn_outage_and_wait() {
  # 45 s is longer than both SSH (ServerAlive, 30 s) and autossh (AUTOSSH_POLL, 30 s)
  # wait before they give up on the old session, so the tunnel has to be rebuilt.
  docker stop -t 2 proxy-forward-e2e-openvpn >/dev/null
  back_at=$(($(date +%s) + 45))
  while [ "$(date +%s)" -lt "$back_at" ]; do sleep 1; done
  docker start proxy-forward-e2e-openvpn >/dev/null
  wait_for_proxy 90
}
tunnel_and_proxy_never_restarted() {
  [ "$(restarts proxy-forward-e2e-tunnel)" -eq 0 ] && [ "$(restarts proxy-forward-e2e-proxy)" -eq 0 ]
}

check "docker restart openvpn: works again within 30 s, no manual step" restart_openvpn_and_wait
check "openvpn killed (SIGKILL) and restarted by Docker: works again within 30 s" crash_openvpn_and_wait
check "VPN down for 45 s: works again within 90 s of the VPN coming back" long_vpn_outage_and_wait
check "tunnel and proxy were never restarted" tunnel_and_proxy_never_restarted

if [ "${E2E_RESTART_DOCKER:-}" = 1 ]; then
  restart_docker_and_wait() {
    sudo systemctl restart docker
    wait_for_proxy 150
  }
  check "Docker daemon restarted (like a reboot): works again within 150 s" restart_docker_and_wait
fi

# --- PROXY_BIND=0.0.0.0 brings the old behaviour back ----------------------------

write_env "PROXY_BIND=0.0.0.0"
compose up -d proxy 2>&1 | tail -n 1
check "PROXY_BIND=0.0.0.0: the remote host still works through the tunnel" wait_for_proxy 30
check "PROXY_BIND=0.0.0.0: a VPN peer can use the proxy directly again" vpn_peer_can_use_proxy
check "PROXY_BIND=0.0.0.0: another container on the Docker network can use it again" \
  docker_neighbour_can_use_proxy

if [ "$failed" -ne 0 ]; then
  echo "--- end-to-end test FAILED"
  exit 1
fi
echo "--- end-to-end test passed"
