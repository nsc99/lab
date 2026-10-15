#!/usr/bin/env bash
# Run in a detached tmux session; reconnect when a rollout replaces the pod.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
trap 'exit 0' INT TERM
while true; do
  "$ROOT/local/cluster.sh" kubectl -n homepage port-forward service/homepage 3000:3000 || true
  echo "Homepage preview disconnected; reconnecting in 2 seconds" >&2
  sleep 2
done
