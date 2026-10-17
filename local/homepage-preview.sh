#!/usr/bin/env bash
# Run in a detached tmux session; reconnect when a rollout replaces the pod.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proxy_pid="" tunnel_pid=""
cleanup() {
  [[ -z $tunnel_pid ]] || kill "$tunnel_pid" 2>/dev/null || true
  [[ -z $proxy_pid ]] || kill "$proxy_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM
python3 "$ROOT/local/homepage-preview.py" &
proxy_pid=$!
while true; do
  # Direct pod connections keep the preview independent of API readiness and
  # kube-proxy restarts. The local proxy preserves the production URL paths.
  if homepage_ip=$("$ROOT/local/cluster.sh" kubectl -n homepage get pods -l app.kubernetes.io/name=homepage --field-selector=status.phase=Running -o jsonpath='{.items[0].status.podIP}') &&
     anker_ip=$("$ROOT/local/cluster.sh" kubectl -n anker get pods -l app.kubernetes.io/name=anker --field-selector=status.phase=Running -o jsonpath='{.items[0].status.podIP}'); then
    ssh -F "$HOME/.lima/lab-local/ssh.config" -S none -o ControlMaster=no \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -N -L "3001:$homepage_ip:3000" -L "3081:$anker_ip:8080" lima-lab-local &
    tunnel_pid=$!
    # Reconnect when a rollout replaces either pod. An API outage leaves the
    # established direct connection alone until the API recovers.
    while kill -0 "$tunnel_pid" 2>/dev/null; do
      sleep 15
      if next_homepage=$("$ROOT/local/cluster.sh" kubectl -n homepage get pods -l app.kubernetes.io/name=homepage --field-selector=status.phase=Running -o jsonpath='{.items[0].status.podIP}') &&
         next_anker=$("$ROOT/local/cluster.sh" kubectl -n anker get pods -l app.kubernetes.io/name=anker --field-selector=status.phase=Running -o jsonpath='{.items[0].status.podIP}'); then
        [[ $next_homepage == "$homepage_ip" && $next_anker == "$anker_ip" ]] || break
      fi
    done
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
    tunnel_pid=""
  fi
  echo "Homepage preview disconnected; reconnecting in 2 seconds" >&2
  sleep 2
done
