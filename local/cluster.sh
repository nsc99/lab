#!/usr/bin/env bash
# Local test cluster for cluster/ (and nix/config/manifests) changes.
# See docs/LOCAL.md for the workflow; `local/cluster.sh help` for commands.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Tools come from the flake's `local` devShell (pinned by nix/flake.lock).
if [[ -z ${LAB_LOCAL_SHELL:-} ]]; then
  command -v nix >/dev/null || { echo "error: nix is required (see docs/LOCAL.md)" >&2; exit 1; }
  exec nix develop "$ROOT/nix#local" --command "$ROOT/local/cluster.sh" "$@"
fi

VM=lab-local
# Machine-wide like the VM: shared by every worktree of this repo.
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/lab-local
LEASE="$STATE/lease"
LEASE_TTL=${LOCAL_LEASE_TTL:-1800}
REGISTRY=127.0.0.1:5050
TIMEOUT=${LOCAL_TIMEOUT:-900}

# Prod is only ever read (diff); everything else goes to the local kubeconfig.
# Pinned to the sops-managed prod kubeconfig, not the current context.
PROD_KUBECONFIG=${LAB_PROD_KUBECONFIG:-$HOME/.kube/lab}
# Where the lab-local context is registered for kubecm/kubectx.
KUBECM_CONFIG=${KUBECM_CONFIG:-$HOME/.kube/config}
export KUBECONFIG="$STATE/kubeconfig"
mkdir -p "$STATE"

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
  local t missing=()
  for t in "$@"; do command -v "$t" >/dev/null || missing+=("$t"); done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]} (see docs/LOCAL.md)"
}

nix_eval() { nix eval --raw "$ROOT/nix#nixosConfigurations.$1"; }

vm_status() { limactl list --format '{{.Status}}' "$VM" 2>/dev/null || true; }

require_cluster() {
  [[ $(vm_status) == Running && -s $KUBECONFIG ]] || die "local cluster is not running, run: local/cluster.sh up"
}

# Exclusive lease on the VM, held by one worktree ($ROOT) at a time. $LEASE has
# one line each: root, branch, pid of the running command (empty when idle),
# epoch of last use. A lease counts as free once its holder is idle (pid not
# alive) for $LEASE_TTL seconds or its worktree is gone.
lease_locked="" lease_held=""

# Guards read-modify-write of $LEASE; mkdir is atomic (macOS has no flock).
lease_lock() {
  local deadline=$((SECONDS + 10))
  until mkdir "$LEASE.lock" 2>/dev/null; do
    ((SECONDS < deadline)) || die "$LEASE.lock held for 10s; remove it if no local/cluster.sh is running"
    sleep 0.1
  done
  lease_locked=1
}

lease_unlock() {
  rmdir "$LEASE.lock"
  lease_locked=""
}

lease_read() {
  holder_root="" holder_branch="" holder_pid="" holder_used=0
  [[ -f $LEASE ]] || return 0
  { read -r holder_root; read -r holder_branch; read -r holder_pid; read -r holder_used; } <"$LEASE"
}

lease_write() {
  printf '%s\n' "$ROOT" "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" "$1" "$(date +%s)" >"$LEASE.tmp"
  mv "$LEASE.tmp" "$LEASE"
}

lease_busy() { [[ -n $holder_pid ]] && kill -0 "$holder_pid" 2>/dev/null; }

lease_expired() {
  [[ ! -d $holder_root ]] || { ! lease_busy && (($(date +%s) - holder_used > LEASE_TTL)); }
}

lease_describe() {
  local state="idle $((($(date +%s) - holder_used) / 60))m"
  lease_busy && state="running pid $holder_pid"
  echo "$holder_root (branch $holder_branch, $state)"
}

# Takes the lease for $ROOT, waiting while another worktree holds it. $1 is
# the pid to record ($$, cleared again on exit) or empty for exec'd commands.
lease_acquire() {
  local pid=$1 waiting_for=""
  trap lease_exit EXIT
  while :; do
    lease_lock
    lease_read
    if [[ -z $holder_root || $holder_root == "$ROOT" ]] || lease_expired; then
      # kubectl & co. next to a running sync of this worktree keep its pid.
      [[ -n $pid || $holder_root != "$ROOT" ]] || ! lease_busy || pid=$holder_pid
      lease_write "$pid"
      lease_unlock
      break
    fi
    lease_unlock
    if [[ $holder_root != "$waiting_for" ]]; then
      log "local cluster is leased by $(lease_describe), waiting"
      log "free it with 'local/cluster.sh release' there, or it expires after ${LEASE_TTL}s idle"
      waiting_for=$holder_root
    fi
    sleep 15
  done
  lease_held=$1
  if [[ -n $holder_root && $holder_root != "$ROOT" ]]; then
    log "took the lease from $holder_root: the cluster holds branch $holder_branch, 'local/cluster.sh sync master' resets it to prod"
  fi
}

# EXIT trap: drops the mutex if the script died holding it and marks the lease
# idle (keeps it for $ROOT) unless another command of $ROOT took it meanwhile.
lease_exit() {
  [[ -z $lease_locked ]] || lease_unlock
  [[ -n $lease_held ]] || return 0
  lease_lock
  lease_read
  [[ $holder_root != "$ROOT" || $holder_pid != "$$" ]] || lease_write ""
  lease_unlock
}

cmd_lease() {
  lease_read
  if [[ -z $holder_root ]]; then
    echo free
  elif lease_expired; then
    echo "free (expired: $(lease_describe))"
  else
    lease_describe
  fi
}

cmd_release() {
  trap lease_exit EXIT
  lease_lock
  lease_read
  if [[ $holder_root == "$ROOT" ]]; then
    rm "$LEASE"
  elif [[ -n $holder_root ]] && ! lease_expired; then
    die "local cluster is leased by $(lease_describe)"
  fi
  lease_unlock
  log "local cluster lease is free"
}

cmd_up() {
  need limactl kubectl flux sops jq curl shasum nix

  case $(vm_status) in
    Running) ;;
    "")
      local k3s_version args=()
      k3s_version=$(nix_eval nix-letsnote1.config.services.k3s.package.version)
      log "creating VM $VM (k3s v$k3s_version, as in prod)"
      if [[ -e /Library/Apple/usr/libexec/oah/libRosettaRuntime ]]; then
        args+=(--set '.vmOpts.vz.rosetta.enabled=true | .vmOpts.vz.rosetta.binfmt=true')
      else
        log "Rosetta not installed: amd64-only images (mokuro-bunko) will not start."
        log "Install with: softwareupdate --install-rosetta --agree-to-license"
      fi
      limactl start --tty=false --name "$VM" \
        --param k3sVersion="v$k3s_version" "${args[@]}" "$ROOT/local/lima.yaml"
      ;;
    *)
      log "starting VM $VM"
      limactl start --tty=false "$VM"
      ;;
  esac

  (umask 077 && sed 's/: default$/: lab-local/' \
    "$(limactl list --format '{{.Dir}}' "$VM")/copied-from-guest/kubeconfig.yaml" >"$KUBECONFIG")
  chmod 600 "$KUBECONFIG"
  register_context
  kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null

  bootstrap
  cmd_sync "$@"
}

# Replaces the lab-local context in $KUBECM_CONFIG (certs change on recreate).
register_context() {
  local tmp
  unregister_context
  tmp=$(mktemp "$KUBECM_CONFIG.XXXXXX")
  KUBECONFIG="$KUBECM_CONFIG:$KUBECONFIG" kubectl config view --flatten >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$KUBECM_CONFIG"
  log "context lab-local registered in $KUBECM_CONFIG (kubecm switch lab-local)"
}

unregister_context() {
  local k
  [[ -f $KUBECM_CONFIG ]] || return 0
  if [[ $(KUBECONFIG=$KUBECM_CONFIG kubectl config current-context 2>/dev/null) == lab-local ]]; then
    KUBECONFIG=$KUBECM_CONFIG kubectl config unset current-context >/dev/null
  fi
  for k in context cluster user; do
    KUBECONFIG=$KUBECM_CONFIG kubectl config "delete-$k" lab-local >/dev/null 2>&1 || true
  done
}

# Same pieces nix/modules/flux.nix drops into k3s's manifests dir on prod.
bootstrap() {
  local flux_nix="$ROOT/nix/modules/flux.nix" version sha manifest
  version=$(sed -n 's/^ *fluxVersion = "\(.*\)";/\1/p' "$flux_nix")
  sha=$(sed -n 's/^ *sha256 = "sha256:\([0-9a-f]*\)";/\1/p' "$flux_nix")
  manifest="$STATE/flux-install-$version.yaml"
  if [[ ! -s $manifest ]]; then
    curl -fsSL -o "$manifest.tmp" "https://github.com/fluxcd/flux2/releases/download/v$version/install.yaml"
    echo "$sha  $manifest.tmp" | shasum -a 256 -c --quiet || die "flux install.yaml does not match flux.nix sha256"
    mv "$manifest.tmp" "$manifest"
  fi
  log "installing flux v$version"
  kubectl apply --server-side --force-conflicts -f "$manifest" >/dev/null
  kubectl -n flux-system wait --for=condition=Available deployment --all --timeout=300s >/dev/null

  log "applying sops-age secret and cluster-settings"
  sops -d --input-type binary --output-type binary "$ROOT/nix/secrets/sops-age.enc" | kubectl apply -f - >/dev/null

  # Prod's cluster-settings, with the values that must point at local things.
  local node_ip
  node_ip=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  nix_eval 'nix-letsnote1.config.services.k3s.manifests."04-cluster-settings.yaml".source.text' |
    jq --arg nfs "$node_ip" '.data.NFS_HOST = $nfs | .data.EXTERNAL_DOMAIN = "lab.test"' |
    kubectl apply -f - >/dev/null

  apply_flux_sync

  log "waiting for local registry"
  local deadline=$((SECONDS + 300))
  until curl -fsS -m 3 "http://$REGISTRY/v2/" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || die "registry not reachable at $REGISTRY"
    sleep 3
  done
}

# Flux stages + local patches (local/flux); re-applied on every sync so
# changes to the patches take effect without recreating the VM.
apply_flux_sync() {
  kubectl kustomize --load-restrictor=LoadRestrictionsNone "$ROOT/local/flux" | kubectl apply -f - >/dev/null
}

# Local stand-ins for external services (local/fixtures) and their Secrets.
# The WireGuard keys are generated once and kept in $STATE/vpn; the gluetun
# Secret also carries the qBittorrent login Sonarr uses, from the arr secret.
# Grafana's contact points go to the local ntfy.
apply_fixtures() {
  need wg sops
  local vpn="$STATE/vpn" k
  mkdir -p "$vpn"
  for k in server client; do
    [[ -s $vpn/$k.key ]] || (umask 077 && wg genkey >"$vpn/$k.key")
    wg pubkey <"$vpn/$k.key" >"$vpn/$k.pub"
  done

  kubectl kustomize "$ROOT/local/fixtures" | apply_local
  jq -n --rawfile server "$vpn/server.key" --rawfile client "$vpn/client.pub" '{
    apiVersion: "v1", kind: "Secret",
    metadata: {name: "vpn-endpoint", namespace: "local-fixtures"},
    stringData: {server_private_key: $server, client_public_key: $client}
  }' | apply_local
  sops -d --extract '["stringData"]' --output-type json "$ROOT/cluster/apps/arr/secret.yaml" |
    jq --rawfile client "$vpn/client.key" --rawfile server "$vpn/server.pub" '{
      apiVersion: "v1", kind: "Secret",
      metadata: {name: "gluetun", namespace: "gluetun"},
      stringData: {
        wireguard_private_key: ($client | rtrimstr("\n")),
        wireguard_public_key: ($server | rtrimstr("\n")),
        wireguard_addresses: "10.64.0.2/32",
        qbittorrent_username, qbittorrent_password
      }
    }' | apply_local
  jq -n --arg ntfy http://ntfy.local-fixtures.svc.cluster.local '{
    apiVersion: "v1", kind: "Secret",
    metadata: {name: "grafana-alerting", namespace: "monitoring"},
    stringData: {NTFY_URL: "\($ntfy)/alerts", HEALTHCHECKS_URL: "\($ntfy)/deadman"}
  }' | apply_local
}

# Server-side, so it shares objects with Flux (the gluetun namespace) cleanly.
apply_local() { kubectl apply --server-side --force-conflicts --field-manager=local-cluster -f - >/dev/null; }

cmd_sync() {
  need flux kubectl jq git rsync
  require_cluster
  local ref=${1:-} src revision
  src=$(mktemp -d)
  trap 'rm -rf "$src"' RETURN

  if [[ -n $ref ]]; then
    git -C "$ROOT" archive "$ref" cluster | tar -x -C "$src"
    revision="$ref@sha1:$(git -C "$ROOT" rev-parse "$ref^{commit}")"
  else
    rsync -a --exclude .DS_Store "$ROOT/cluster" "$src/"
    revision="$(git -C "$ROOT" branch --show-current)@sha1:$(git -C "$ROOT" rev-parse HEAD)"
    [[ -z $(git -C "$ROOT" status --porcelain -- cluster) ]] || log "syncing uncommitted changes in cluster/"
  fi

  apply_flux_sync
  apply_fixtures
  log "pushing ${ref:-working tree} to local registry"
  flux push artifact "oci://$REGISTRY/lab:local" --insecure-registry --path "$src" \
    --source "$(git -C "$ROOT" config --get remote.origin.url)" --revision "$revision" >/dev/null
  flux reconcile source oci lab >/dev/null

  wait_healthy
}

# Prints one line per object that is not (yet) healthy.
unhealthy() {
  local rev
  rev=$(kubectl -n flux-system get ocirepository lab -o jsonpath='{.status.artifact.revision}')
  kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io,deployments,statefulsets,daemonsets,jobs \
    -A -o json | jq -r --arg rev "$rev" '
    def cond(t): (.status.conditions // []) | map(select(.type == t)) | first // {};
    def current: (.status.observedGeneration // -1) == .metadata.generation;
    .items[]
    | "\(.kind) \(.metadata.namespace)/\(.metadata.name)" as $id
    | if .kind == "Kustomization" then
        select((current and cond("Ready").status == "True" and .status.lastAppliedRevision == $rev) | not)
        | "\($id): \(cond("Ready").message // "pending")"
      elif .kind == "HelmRelease" then
        select((current and cond("Ready").status == "True") | not)
        | "\($id): \(cond("Ready").message // "pending")"
      elif .kind == "Deployment" then
        select((current and (.status.updatedReplicas // 0) == .spec.replicas
                and (.status.availableReplicas // 0) == .spec.replicas) | not)
        | "\($id): \(.status.availableReplicas // 0)/\(.spec.replicas) available"
      elif .kind == "StatefulSet" then
        select((current and (.status.readyReplicas // 0) == .spec.replicas
                and .status.currentRevision == .status.updateRevision) | not)
        | "\($id): \(.status.readyReplicas // 0)/\(.spec.replicas) ready"
      elif .kind == "DaemonSet" then
        select((current and .status.updatedNumberScheduled == .status.desiredNumberScheduled
                and (.status.numberAvailable // 0) == .status.desiredNumberScheduled) | not)
        | "\($id): \(.status.numberAvailable // 0)/\(.status.desiredNumberScheduled) available"
      else
        select(cond("Failed").status == "True") | "\($id): \(cond("Failed").message)"
      end'
}

wait_healthy() {
  log "waiting for flux and workloads (timeout ${TIMEOUT}s)"
  local deadline=$((SECONDS + TIMEOUT)) bad=""
  while ((SECONDS < deadline)); do
    bad=$(unhealthy)
    [[ -z $bad ]] && break
    # A failed health check otherwise waits for retryInterval.
    kubectl -n flux-system annotate --overwrite kustomizations.kustomize.toolkit.fluxcd.io --all \
      reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null
    sleep 15
  done
  report "$bad"
}

report() {
  local bad=$1
  flux get kustomizations
  echo
  flux get helmreleases -A
  if [[ -n $bad ]]; then
    echo
    log "not healthy:"
    echo "$bad"
    echo
    log "pods not running:"
    kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
    kubectl get pods -A -o json | jq -r '.items[]
      | select(.status.phase == "Running" and any(.status.containerStatuses[]?; .ready | not))
      | "\(.metadata.namespace)/\(.metadata.name): containers not ready"'
    echo
    log "recent warning events:"
    kubectl get events -A --field-selector=type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -20
    return 1
  fi
  log "local cluster is healthy"
}

cmd_status() {
  need flux kubectl jq
  log "lease: $(cmd_lease)"
  require_cluster
  report "$(unhealthy)"
}

# End-to-end checks of the workloads that talk to local/fixtures stand-ins.
cmd_verify() {
  need kubectl jq
  require_cluster
  verify_gluetun
  verify_alerting
  log "verify passed"
}

# Grafana Alerting: Watchdog pings the dead-man check and a firing Prometheus
# alert reaches ntfy (both topics on the local/fixtures ntfy).
verify_alerting() {
  local since
  since=$(date +%s)
  kubectl -n local-fixtures rollout status deployment/ntfy --timeout=120s >/dev/null || die "ntfy is not available"

  log "alerting: Watchdog pings the dead-man check"
  # Only Watchdog is routed there; its body may arrive as an attachment.
  wait_ntfy deadman "$since" '"event":"message"' || die "no ping on the deadman topic"

  # verify_run makes a new alert instance even while the last run's one has
  # not resolved yet in Grafana; "firing" skips that run's resolved message.
  log "alerting: a firing Prometheus alert reaches ntfy"
  since=$(date +%s)
  kubectl apply -f - >/dev/null <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: local-verify
  namespace: monitoring
  labels:
    release: observability
spec:
  groups:
    - name: local-verify
      rules:
        - alert: LocalVerify
          expr: vector(1)
          labels:
            severity: warning
            verify_run: "$since"
EOF
  wait_ntfy alerts "$since" "firing LocalVerify" || {
    kubectl -n monitoring delete prometheusrule local-verify >/dev/null
    die "LocalVerify did not reach the alerts topic"
  }
  kubectl -n monitoring delete prometheusrule local-verify >/dev/null
}

# Waits up to 10 minutes for a message on ntfy topic $1 since $2 (unix time or
# "all") whose JSON matches $3.
wait_ntfy() {
  local deadline=$((SECONDS + 600)) out
  # Not piped into grep -q: with pipefail an early grep exit fails the pipe.
  until out=$(kubectl -n local-fixtures exec deployment/ntfy -- wget -qO- "http://localhost/$1/json?poll=1&since=$2") &&
    [[ $out == *"$3"* ]]; do
    ((SECONDS < deadline)) || return 1
    sleep 10
  done
}

# qBittorrent behind gluetun: traffic leaves through the tunnel, nothing gets
# out while the tunnel is down (kill switch) and it recovers, the WebUI takes
# Sonarr's login on its ingress, and Sonarr's download client test passes.
verify_gluetun() {
  local domain size=2000000 before after deadline
  domain=$(kubectl -n flux-system get configmap cluster-settings -o jsonpath='{.data.EXTERNAL_DOMAIN}')
  kubectl -n gluetun rollout status deployment/gluetun --timeout=300s >/dev/null || die "gluetun is not available"
  kubectl -n local-fixtures rollout status deployment/vpn-endpoint --timeout=120s >/dev/null || die "vpn-endpoint is not available"

  log "gluetun: qbittorrent's traffic goes through the tunnel"
  before=$(endpoint_tx)
  qbittorrent curl -fsS -m 30 -o /dev/null "https://speed.cloudflare.com/__down?bytes=$size" ||
    die "qbittorrent has no internet access through gluetun"
  after=$(endpoint_tx)
  ((after - before >= size)) || die "download worked but only $((after - before)) bytes passed the VPN endpoint (leak?)"

  # gluetun notices a dead tunnel after ~3 min (periodic healthcheck) and then
  # restarts the VPN, which rebuilds routes and firewall: the moment a leak
  # would happen. Probe until 30s past that restart.
  log "gluetun: kill switch (tunnel down until gluetun has restarted the VPN, ~3 min)"
  local since restarted=""
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  trap 'endpoint ip link set wg0 up >/dev/null 2>&1 || true; lease_exit' EXIT
  endpoint ip link set wg0 down
  deadline=$((SECONDS + 300))
  while [[ -z $restarted ]] || ((SECONDS < restarted + 30)); do
    # By IP, so a missing DNS answer cannot hide a leak.
    ! qbittorrent curl -fsS -m 5 -o /dev/null https://1.1.1.1/cdn-cgi/trace 2>/dev/null ||
      die "qbittorrent reached the internet with the tunnel down"
    if [[ -z $restarted ]] && kubectl -n gluetun logs deployment/gluetun -c gluetun --since-time="$since" | grep -q 'restarting VPN'; then
      restarted=$SECONDS
    fi
    [[ -n $restarted ]] || ((SECONDS < deadline)) || die "gluetun did not restart the VPN within 300s of the tunnel going down"
    sleep 3
  done
  endpoint ip link set wg0 up
  trap lease_exit EXIT

  log "gluetun: traffic resumes once the tunnel is back"
  deadline=$((SECONDS + 300))
  until qbittorrent curl -fsS -m 5 -o /dev/null https://1.1.1.1/cdn-cgi/trace 2>/dev/null; do
    ((SECONDS < deadline)) || die "gluetun did not recover within 300s"
    sleep 5
  done

  log "qbittorrent: WebUI login on https://q.$domain"
  local out
  # Credentials go in on stdin; $u/$p/$1 expand in the pod.
  # shellcheck disable=SC2016
  out=$(kubectl -n gluetun get secret gluetun -o json |
    jq -r '.data | (.qbittorrent_username, .qbittorrent_password) | @base64d' |
    endpoint_stdin sh -c 'read -r u; read -r p; curl -sSk -w " %{http_code}" -H "Referer: https://q.$1" \
      --data-urlencode "username=$u" --data-urlencode "password=$p" "https://q.$1/api/v2/auth/login"' - "$domain") ||
    die "qbittorrent WebUI not reachable on https://q.$domain"
  # 204 on success, 401 on bad credentials.
  [[ $out == " 204" ]] || die "qbittorrent rejected Sonarr's login: $out"

  # Configarr (re)creates Sonarr's download client; run it now instead of
  # waiting for the schedule.
  log "sonarr: arr-config job with the download client enabled"
  local job
  job=arr-config-verify-$(date +%s)
  kubectl -n arr create job --from=cronjob/arr-config "$job" >/dev/null
  deadline=$((SECONDS + 600))
  until [[ $(kubectl -n arr get job "$job" -o jsonpath='{.status.succeeded}') == 1 ]]; do
    if [[ $(kubectl -n arr get job "$job" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}') == True ]] ||
      ((SECONDS >= deadline)); then
      kubectl -n arr logs "job/$job" --all-containers --tail=30 >&2 || true
      kubectl -n arr delete job "$job" --wait=false >/dev/null
      die "arr-config job $job did not succeed"
    fi
    sleep 5
  done
  kubectl -n arr delete job "$job" --wait=false >/dev/null

  log "sonarr: download client test"
  # shellcheck disable=SC2016
  out=$(kubectl -n arr get secret arr -o jsonpath='{.data.sonarr_api_key}' | base64 -d |
    endpoint_stdin sh -c 'read -r k; curl -fsSk -X POST -H "X-Api-Key: $k" "https://sonarr.$1/api/v3/downloadclient/testall"' - "$domain") ||
    die "sonarr download client test request failed"
  jq -e 'length > 0 and all(.isValid)' <<<"$out" >/dev/null || die "sonarr download client test failed: $out"
}

endpoint() { kubectl -n local-fixtures exec deployment/vpn-endpoint -c wireguard -- "$@"; }
endpoint_stdin() { kubectl -n local-fixtures exec -i deployment/vpn-endpoint -c wireguard -- "$@"; }
qbittorrent() { kubectl -n gluetun exec deployment/gluetun -c qbittorrent -- "$@"; }
# Bytes the VPN endpoint sent to gluetun.
endpoint_tx() { endpoint wg show wg0 transfer | awk '{print $3}'; }

# Same checks as CI, plus evaluating every NixOS host.
cmd_check() {
  need kustomize kubeconform nix
  local dir host
  for dir in cluster/infra/controllers cluster/infra/configs cluster/apps; do
    log "kubeconform $dir"
    kustomize build "$ROOT/$dir" | kubeconform -summary -ignore-missing-schemas \
      -schema-location default \
      -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  done
  for host in $(nix eval --json "$ROOT/nix#nixosConfigurations" --apply builtins.attrNames | jq -r '.[]'); do
    log "evaluating $host"
    nix_eval "$host.config.system.build.toplevel.drvPath" >/dev/null
  done
  log "nix flake check"
  (cd "$ROOT/nix" && nix flake check)
}

# Read-only server-side dry run of the working tree against prod.
cmd_diff() {
  need flux kubectl
  local server
  server=$(KUBECONFIG=$PROD_KUBECONFIG kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  [[ $server != *127.0.0.1* ]] || die "$PROD_KUBECONFIG points at the local cluster ($server)"
  log "diffing against $server ($PROD_KUBECONFIG)"
  local ks rc=0
  for ks in infra-controllers:cluster/infra/controllers infra-configs:cluster/infra/configs apps:cluster/apps; do
    log "${ks%%:*}"
    flux diff kustomization "${ks%%:*}" --path "$ROOT/${ks#*:}" --kubeconfig "$PROD_KUBECONFIG" --progress-bar=false || rc=$?
  done
  # flux diff exits 1 when there are changes; only >1 is an error.
  ((rc <= 1))
}

usage() {
  cat <<'EOF'
usage: local/cluster.sh <command> [args]

  up [ref]      create/start the VM, bootstrap flux, then sync
  sync [ref]    push cluster/ (working tree, or git ref) and wait until healthy
  status        flux + workload health of the local cluster
  check         CI checks (kustomize | kubeconform), nix eval of all hosts, flake check
  diff          read-only diff of the working tree against prod
  verify        end-to-end checks against local/fixtures (qBittorrent/gluetun, alerting)
  kubectl ...   kubectl against the local cluster
  flux ...      flux against the local cluster
  k9s           k9s against the local cluster
  shell         shell into the VM
  stop          stop the VM (state is kept)
  destroy       delete the VM, release the lease
  lease         show which worktree holds the local cluster
  release       release the lease of this worktree (when done with the cluster)

Every command that uses the VM (up, sync, verify, kubectl, flux, k9s, shell,
stop, destroy) waits until no other worktree holds the lease, then takes it.
EOF
}

cmd=${1:-help}
shift || true
case $cmd in
  up | sync | verify) lease_acquire "$$"; "cmd_$cmd" "$@" ;;
  status | check | diff | lease | release) "cmd_$cmd" "$@" ;;
  kubectl | flux | k9s) lease_acquire ""; require_cluster; exec "$cmd" "$@" ;;
  shell) lease_acquire ""; exec limactl shell "$VM" "$@" ;;
  stop) lease_acquire "$$"; limactl stop "$VM" ;;
  destroy) lease_acquire "$$"; limactl delete --force "$VM"; rm -f "$KUBECONFIG"; unregister_context; cmd_release ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 1 ;;
esac
