#!/bin/sh
# End-to-end test without a real VPN or a real server.
#
# Starts a throwaway "remote host" (an OpenVPN server that also runs sshd and
# is reachable only through the VPN), points the real docker-compose.yml at
# it, and checks that a program on that host can use the proxy through the
# reverse tunnel. Then it checks the things that are easy to break:
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
#         and internet access (it fetches a public web page through the proxy).
set -eu
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: pass container paths through untouched

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

# --- test settings, defined once here ------------------------------------------
# Scratch folder, relative to the repo root (it is also listed in .gitignore).
work_rel=tests/e2e/.work
work="$root/$work_rel"

# The user, ports and file layout are the ones from .env.example, so the test
# runs the documented example configuration.
example_value() { sed -n "s/^$1=//p" "$root/.env.example"; }
ssh_user=$(example_value REMOTE_USER)
remote_port=$(example_value REMOTE_PORT)
proxy_port=$(example_value PROXY_PORT)
key_file=$(example_value SSH_KEY_PATH)
key_file=${key_file#./}
ovpn_file=$(example_value OVPN_CONFIG_PATH)
ovpn_file=${ovpn_file#./}

# The test VPN is $vpn_net.0/24; OpenVPN's `server` directive gives the server
# .1 and the first (only) client .2.
vpn_net=10.8.0
server_ip=$vpn_net.1
client_ip=$vpn_net.2

# What the remote host fetches through the proxy: a page over HTTPS, and the
# same site over plain HTTP.
test_url=https://example.com/
plain_url="http://${test_url#https://}"

# Time limits, in seconds.
startup_limit=150  # first start, including image builds and the VPN handshake
restart_limit=30   # a quick openvpn restart must not even reach SSH's 30 s ServerAlive timeout
outage=45          # longer than that timeout, so SSH has to log in again
outage_limit=90    # ConnectTimeout (10 s) + autossh retry gap (up to AUTOSSH_POLL, 30 s) + margin
recreate_limit=60  # after `compose up -d` recreates containers; the tunnel logs in again
poll_timeout=5     # one request while waiting for the proxy
request_timeout=20 # one request in a check

# compose.e2e.yml, gen.sh and vpnserver.sh read these.
HOST_UID=$(id -u) HOST_GID=$(id -g)
export HOST_UID HOST_GID E2E_WORK="$work_rel" E2E_VPN_NET="$vpn_net" E2E_SSH_USER="$ssh_user" \
  E2E_KEY_FILE="$key_file" E2E_OVPN_FILE="$ovpn_file"

# --- helpers ----------------------------------------------------------------------

# Docker needs Windows-style paths when this runs in Git Bash.
hostpath() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }

compose() {
  docker compose -p proxy-forward-e2e --project-directory "$(hostpath "$root")" \
    -f "$(hostpath "$root")/docker-compose.yml" -f "$(hostpath "$here")/compose.e2e.yml" \
    --env-file "$(hostpath "$work")/.env" "$@"
}
cid() { compose ps -a -q "$1"; } # container id of a service
on_remote() { compose exec -T vpnserver "$@"; }
# How many log lines of a service match a pattern (compared before and after an event).
log_count() { compose logs --no-color "$1" 2>&1 | grep -c "$2" || true; }

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
REMOTE_HOST=$server_ip
REMOTE_USER=$ssh_user
REMOTE_PORT=$remote_port
SSH_KEY_PATH=./$work_rel/$key_file
OVPN_CONFIG_PATH=./$work_rel/$ovpn_file
PROXY_PORT=$proxy_port
$1
EOF
}

remote_request_ok() {
  on_remote curl -fsS -m "$poll_timeout" -o /dev/null \
    -x "socks5h://127.0.0.1:$remote_port" "$test_url" >/dev/null 2>&1
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

failed=0
check() {
  name=$1
  shift
  if out=$("$@" 2>&1); then
    echo "ok   $name${out:+  ($(printf '%s' "$out" | tail -n 1))}"
  else
    echo "FAIL $name"
    printf '%s\n' "$out" | tail -n 25
    failed=1
  fi
}
not() { ! "$@"; }

# --- start ------------------------------------------------------------------------

rm -rf "$work"
mkdir -p "$work"
write_env ""
trap cleanup EXIT INT TERM

echo "--- generating a test CA, VPN certs and an SSH key"
compose run --rm --build --quiet-pull gen

echo "--- starting the stack"
compose up -d --build --quiet-pull 2>&1 | tail -n 5

echo "--- waiting for the reverse tunnel (up to $startup_limit seconds)"
wait_for_proxy "$startup_limit"

# --- the basic path -----------------------------------------------------------

# The interface that holds this machine's VPN address, and the one Docker gave
# the shared network (it carries the default route).
vpn_dev() { compose exec -T netns ip -4 -o addr | awk -v ip="$client_ip/" 'index($4, ip) == 1 {print $2}'; }
docker_dev() { compose exec -T netns ip route show default | awk '{print $5; exit}'; }

ssh_came_through_vpn() { [ "$(log_count vpnserver "Accepted publickey for $ssh_user from $client_ip")" -gt 0 ]; }
default_route_not_on_vpn() {
  dev=$(vpn_dev)
  [ -n "$dev" ] || return 1
  ! compose exec -T netns ip route | grep -E "^(default|0\.0\.0\.0/1|128\.0\.0\.0/1) .*dev $dev"
}
remote_port_on_loopback_only() {
  listeners=$(on_remote netstat -tln | grep ":$remote_port ")
  [ -n "$listeners" ] && ! echo "$listeners" | grep -q -v -E "127\.0\.0\.1:$remote_port|::1:$remote_port"
}

check "SOCKS5 (socks5h://) from the remote host" \
  on_remote curl -fsS -m "$request_timeout" -o /dev/null -x "socks5h://127.0.0.1:$remote_port" "$test_url"
check "HTTP proxy, HTTPS site (CONNECT)" \
  on_remote curl -fsS -m "$request_timeout" -o /dev/null -x "http://127.0.0.1:$remote_port" "$test_url"
check "HTTP proxy, plain HTTP site" \
  on_remote curl -fsS -m "$request_timeout" -o /dev/null -x "http://127.0.0.1:$remote_port" "$plain_url"
check "SSH came in through the VPN (from $client_ip)" ssh_came_through_vpn
check "route-nopull kept the default route off the VPN" default_route_not_on_vpn
check "remote port $remote_port listens on loopback only" remote_port_on_loopback_only

# --- who else can use the proxy ----------------------------------------------
# The test server is both a VPN peer (it reaches this machine at $client_ip)
# and a neighbour on the Docker network (it reaches the shared network there).

# Looked up each time, because the address can change when Docker restarts.
shared_ip() { compose exec -T netns ip -4 -o addr show dev "$(docker_dev)" | awk '{print $4}' | cut -d/ -f1; }
vpn_peer_can_use_proxy() {
  on_remote curl -fsS -m "$request_timeout" -o /dev/null -x "http://$client_ip:$proxy_port" "$plain_url"
}
docker_neighbour_can_use_proxy() {
  on_remote curl -fsS -m "$request_timeout" -o /dev/null -x "http://$(shared_ip):$proxy_port" "$plain_url"
}

check "default: a VPN peer can NOT use the proxy directly ($client_ip:$proxy_port)" not vpn_peer_can_use_proxy
check "default: a neighbour on the Docker network can NOT use it" not docker_neighbour_can_use_proxy

# --- nothing gets installed when openvpn starts --------------------------------

openvpn_image() { docker inspect -f '{{.Config.Image}}' "$(cid openvpn)"; }
openvpn_is_in_the_image() {
  version=$(docker run --rm --network none --entrypoint openvpn "$(openvpn_image)" --version) || return 1
  printf '%s\n' "$version" | head -n 1
}
no_package_install_in_openvpn_logs() {
  ! compose logs --no-color openvpn | grep -E 'fetch https?://|OK: [0-9.]+ [KMG]i?B in [0-9]+ packages'
}
check "the openvpn image already contains OpenVPN (runs with no network)" openvpn_is_in_the_image
check "the openvpn container installed no packages at start-up" no_package_install_in_openvpn_logs

# --- the proxy comes back on its own after openvpn goes away --------------------

restarts() { docker inspect -f '{{.RestartCount}}' "$(cid "$1")"; }
show_openvpn_state() {
  docker inspect -f 'openvpn: {{.State.Status}}, restarts={{.RestartCount}}' "$(cid openvpn)"
  compose exec -T netns ip addr 2>&1 | grep -E '^[0-9]+:|inet '
  compose logs --no-color --tail 12 openvpn 2>&1
}

restart_openvpn_and_wait() {
  docker restart "$(cid openvpn)" >/dev/null
  wait_for_proxy "$restart_limit"
}
crash_openvpn_and_wait() {
  restarts_before=$(restarts openvpn)
  leftovers_before=$(log_count openvpn "removing leftover")
  pid=$(docker inspect -f '{{.State.Pid}}' "$(cid openvpn)")
  # SIGKILL from outside, like an OOM kill; the restart policy brings it back.
  docker run --rm --pid=host "$(openvpn_image)" kill -9 "$pid"
  if ! took=$(wait_for_proxy "$restart_limit"); then
    echo "$took"
    show_openvpn_state
    return 1
  fi
  [ "$(restarts openvpn)" -gt "$restarts_before" ] || return 1
  # With kernel DCO the killed OpenVPN leaves its interface behind; start-openvpn removes it.
  if [ "$(log_count openvpn "removing leftover")" -gt "$leftovers_before" ]; then
    echo "$took; a leftover DCO interface was removed first"
  else
    echo "$took"
  fi
}
long_vpn_outage_and_wait() {
  logins_before=$(log_count vpnserver "Accepted publickey for $ssh_user")
  docker stop -t 2 "$(cid openvpn)" >/dev/null
  back_at=$(($(date +%s) + outage))
  while [ "$(date +%s)" -lt "$back_at" ]; do sleep 1; done
  docker start "$(cid openvpn)" >/dev/null
  if ! took=$(wait_for_proxy "$outage_limit"); then
    echo "$took"
    show_openvpn_state
    return 1
  fi
  logins=$(($(log_count vpnserver "Accepted publickey for $ssh_user") - logins_before))
  echo "$took; SSH logins during the outage: $logins"
}
tunnel_and_proxy_never_restarted() {
  [ "$(restarts tunnel)" -eq 0 ] && [ "$(restarts proxy)" -eq 0 ]
}

check "openvpn restarted: works again within $restart_limit s, no manual step" restart_openvpn_and_wait
check "openvpn killed (SIGKILL) and restarted by Docker: works again within $restart_limit s" \
  crash_openvpn_and_wait
check "VPN down for $outage s: works again within $outage_limit s of the VPN coming back" \
  long_vpn_outage_and_wait
check "tunnel and proxy were never restarted" tunnel_and_proxy_never_restarted

if [ "${E2E_RESTART_DOCKER:-}" = 1 ]; then
  restart_docker_and_wait() {
    sudo systemctl restart docker
    wait_for_proxy "$startup_limit"
  }
  check "Docker daemon restarted (like a reboot): works again within $startup_limit s" \
    restart_docker_and_wait
fi

# --- PROXY_BIND=0.0.0.0 brings the old behaviour back ----------------------------

# Same as the README: change .env, then `docker compose up -d` for the whole
# project. (Naming only `proxy` can make Compose recreate netns without
# recreating openvpn and tunnel, which strands them in the old network.)
write_env "PROXY_BIND=0.0.0.0"
compose up -d 2>&1 | grep -E 'Recreated' || true
check "PROXY_BIND=0.0.0.0: the remote host still works through the tunnel" wait_for_proxy "$recreate_limit"
check "PROXY_BIND=0.0.0.0: a VPN peer can use the proxy directly again" vpn_peer_can_use_proxy
check "PROXY_BIND=0.0.0.0: a neighbour on the Docker network can use it again" \
  docker_neighbour_can_use_proxy

if [ "$failed" -ne 0 ]; then
  echo "--- end-to-end test FAILED"
  exit 1
fi
echo "--- end-to-end test passed"
