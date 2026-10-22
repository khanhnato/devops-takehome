# shellcheck shell=bash
# Shared helpers, sourced by every numbered script.
#
# Every script can be started from the host OR from inside the toolbox:
# on the host it transparently re-executes itself inside the toolbox
# container, where kubectl/helm/terraform/k6 live.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-quote}"
APP_NS="${APP_NS:-quote}"
# In-cluster address of the k3d load balancer (Traefik ingress on :80).
INGRESS_URL="${INGRESS_URL:-http://k3d-${CLUSTER_NAME}-serverlb}"
HTTP_PORT="${HTTP_PORT:-8080}"
ARGOCD_PORT="${ARGOCD_PORT:-8081}"

if [ -z "${IN_TOOLBOX:-}" ]; then
  command -v docker >/dev/null || { echo "docker not found on PATH" >&2; exit 1; }
  if ! docker compose -f "$REPO_ROOT/docker-compose.yml" ps --status running --services 2>/dev/null | grep -qx toolbox; then
    echo "The toolbox container is not running. Start it first:  docker compose up -d" >&2
    exit 1
  fi
  # No arrays here: macOS ships bash 3.2, where an empty "${arr[@]}" trips `set -u`.
  no_tty="-T"; [ -t 0 ] && [ -t 1 ] && no_tty=""
  script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  exec docker compose -f "$REPO_ROOT/docker-compose.yml" exec ${no_tty:+"$no_tty"} toolbox \
    "/workspace/${script#"$REPO_ROOT"/}" "$@"
fi

if [ -t 1 ]; then
  _c() { printf '\033[%sm' "$1"; }
else
  _c() { :; }
fi
log()  { echo "$(_c '1;34')==>$(_c 0) $*"; }
ok()   { echo "$(_c '1;32')OK$(_c 0)  $*"; }
warn() { echo "$(_c '1;33')WARN$(_c 0) $*" >&2; }
die()  { echo "$(_c '1;31')ERROR$(_c 0) $*" >&2; exit 1; }

# Block until the toolbox entrypoint has finished bootstrapping the cluster.
wait_for_bootstrap() {
  local status i
  for i in $(seq 1 180); do
    status="$(cat /tmp/bootstrap.status 2>/dev/null || echo running)"
    case "$status" in
      ok) return 0 ;;
      failed) tail -n 40 /tmp/bootstrap.log >&2; die "cluster bootstrap failed (full log: docker compose logs toolbox)" ;;
    esac
    [ "$i" = 1 ] && log "Waiting for cluster bootstrap to finish (docker compose logs -f toolbox)..."
    sleep 5
  done
  die "timed out waiting for cluster bootstrap"
}

# retry <attempts> <sleep-seconds> <command...>
retry() {
  local n=$1 s=$2 i; shift 2
  for i in $(seq 1 "$n"); do
    "$@" && return 0
    [ "$i" -lt "$n" ] && sleep "$s"
  done
  return 1
}

# Print quote-api pods with the nodepool each one landed on.
# Sets PLACEMENT_SPOT / PLACEMENT_OD / PLACEMENT_GPU / PLACEMENT_PENDING counters.
show_placement() {
  local nodes
  nodes="$(kubectl get nodes -o json | jq -c '[.items[] | {key: .metadata.name,
    value: (.metadata.labels["acme.io/capacity"] // .metadata.labels["acme.io/node-type"] // "none")}] | from_entries')"
  PLACEMENT_SPOT=0 PLACEMENT_OD=0 PLACEMENT_GPU=0 PLACEMENT_PENDING=0
  printf '  %-34s %-10s %-24s %s\n' POD PHASE NODE POOL
  while read -r pod phase node; do
    local pool
    pool="$(echo "$nodes" | jq -r --arg n "$node" '.[$n] // "-"')"
    printf '  %-34s %-10s %-24s %s\n' "$pod" "$phase" "$node" "$pool"
    case "$pool" in
      spot) PLACEMENT_SPOT=$((PLACEMENT_SPOT + 1)) ;;
      on-demand) PLACEMENT_OD=$((PLACEMENT_OD + 1)) ;;
      gpu) PLACEMENT_GPU=$((PLACEMENT_GPU + 1)) ;;
      *) PLACEMENT_PENDING=$((PLACEMENT_PENDING + 1)) ;;
    esac
  done < <(kubectl -n "$APP_NS" get pods -l app.kubernetes.io/name=quote-api -o json \
    | jq -r '.items[] | select(.metadata.deletionTimestamp == null)
             | "\(.metadata.name) \(.status.phase) \(.spec.nodeName // "-")"')
  echo "  => spot=$PLACEMENT_SPOT on-demand=$PLACEMENT_OD gpu=$PLACEMENT_GPU unscheduled=$PLACEMENT_PENDING"
}

# Fail unless the placement policy holds: >=1 on-demand, nothing on GPU.
assert_placement() {
  show_placement
  [ "$PLACEMENT_GPU" -eq 0 ] || die "a quote-api pod landed on the GPU node"
  [ "$PLACEMENT_OD" -ge 1 ] || die "no quote-api replica on the on-demand node"
  ok "placement policy holds"
}
