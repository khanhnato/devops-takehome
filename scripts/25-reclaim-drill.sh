#!/usr/bin/env bash
# Part 2: availability drills, with a curl loop hitting the ingress throughout.
#   Phase 1 - spot reclaim: drain a spot node that runs a replica, show the pods
#             rescheduling, check the placement policy still holds, uncordon.
#   Phase 2 - on-demand loss + recovery: drain the on-demand node (replicas must
#             fall back to spot, none Pending), uncordon it, and wait for the
#             descheduler to put a replica back on on-demand.
# Fails if any request fails (MAX_ERRORS, default 0). Idempotent.
source "$(dirname "$0")/lib/common.sh"
wait_for_bootstrap

MAX_ERRORS="${MAX_ERRORS:-0}"
SEL=app.kubernetes.io/name=quote-api

kubectl -n "$APP_NS" get deploy quote-api >/dev/null 2>&1 || die "quote-api is not deployed; run scripts/20-deploy.sh first"

# A previous interrupted run may have left a node cordoned.
for n in $(kubectl get nodes -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{" "}{end}'); do
  warn "uncordoning $n left over from a previous run"; kubectl uncordon "$n"
done
kubectl -n "$APP_NS" rollout status deploy/quote-api --timeout=180s

log "Placement before the drills"
show_placement

out="$(mktemp)"
drained=""
cleanup() {
  [ -n "${loop_pid:-}" ] && kill "$loop_pid" 2>/dev/null || true
  [ -n "$drained" ] && kubectl uncordon "$drained" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Starting traffic: curl loop against $INGRESS_URL/api/quote (runs through both phases)"
(
  while :; do
    body="$(curl -s --max-time 3 -w '\n%{http_code}' "$INGRESS_URL/api/quote" || true)"
    code="$(tail -n1 <<<"$body")"
    pod="$(head -n1 <<<"$body" | jq -r '.served_by // "-"' 2>/dev/null || echo -)"
    echo "$(date +%T) $code $pod"
    sleep 0.2
  done
) >"$out" &
loop_pid=$!
sleep 3

# drain <node>: cordon + evict (respects the PDB), then wait until all replicas are Ready.
drain() {
  local start ready=0 want=1
  drained="$1"; start=$(date +%s)
  kubectl drain "$1" --ignore-daemonsets --delete-emptydir-data --timeout=180s
  for _ in $(seq 1 90); do
    read -r want ready <<<"$(kubectl -n "$APP_NS" get deploy quote-api -o jsonpath='{.spec.replicas} {.status.readyReplicas}')"
    ready="${ready:-0}"
    [ "$ready" -ge "$want" ] && break
    sleep 2
  done
  [ "$ready" -ge "$want" ] || die "only $ready/$want replicas became ready after draining $1"
  ok "$ready/$want replicas ready, $(( $(date +%s) - start ))s after the drain of $1 started"
}

uncordon() { kubectl uncordon "$1"; drained=""; }

# ---------------------------------------------------------------- phase 1
# Victim: a spot node that currently hosts a replica.
victim="$(kubectl -n "$APP_NS" get pods -l "$SEL" -o json | jq -r '.items[].spec.nodeName' | sort -u \
  | grep -Fx -f <(kubectl get nodes -l acme.io/capacity=spot -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') \
  | head -n1 || true)"
[ -n "$victim" ] || die "no quote-api replica on a spot node; nothing to reclaim"

echo
log "PHASE 1 - spot reclaim: draining $victim"
drain "$victim"
log "Scheduling events"
# Scheduler events carry eventTime/creationTimestamp, not lastTimestamp.
kubectl -n "$APP_NS" get events --field-selector reason=Scheduled --sort-by=.metadata.creationTimestamp \
  -o custom-columns=TIME:.metadata.creationTimestamp,POD:.involvedObject.name,MESSAGE:.message | tail -n 4
log "Placement after the spot reclaim"
assert_placement
kubectl -n "$APP_NS" get pods -l "$SEL" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | grep -qx "$victim" && die "a replica is still on the drained node $victim"
log "Uncordoning $victim (spot capacity is back)"
uncordon "$victim"

# ---------------------------------------------------------------- phase 2
od_node="$(kubectl get nodes -l acme.io/capacity=on-demand -o jsonpath='{.items[0].metadata.name}')"
echo
log "PHASE 2 - on-demand loss: draining $od_node (the whole on-demand pool)"
drain "$od_node"
log "Placement with no on-demand capacity (expect all on spot, none Pending)"
show_placement
[ "$PLACEMENT_PENDING" -eq 0 ] || die "replicas stuck Pending without on-demand capacity: the spread constraint is too hard"
[ "$PLACEMENT_GPU" -eq 0 ] || die "a replica fell back onto the GPU node"

log "Uncordoning $od_node and waiting for the descheduler to restore an on-demand replica (up to 4 min)"
uncordon "$od_node"
start=$(date +%s)
od=0
for _ in $(seq 1 48); do
  od=$(kubectl -n "$APP_NS" get pods -l "$SEL" -o json | jq --arg n "$od_node" \
    '[.items[] | select(.metadata.deletionTimestamp == null and .spec.nodeName == $n and .status.phase == "Running")] | length')
  [ "$od" -ge 1 ] && break
  sleep 5
done
[ "$od" -ge 1 ] || die "no replica moved back to on-demand (is the descheduler running? kubectl -n kube-system logs deploy/descheduler)"
ok "on-demand replica restored $(( $(date +%s) - start ))s after the node came back"
kubectl -n "$APP_NS" rollout status deploy/quote-api --timeout=120s >/dev/null
sleep 3   # a little traffic on the final layout
kill "$loop_pid"; loop_pid=""

log "Placement after both drills"
assert_placement

# ---------------------------------------------------------------- traffic
total=$(wc -l <"$out" | tr -d ' ')
errors=$(awk '$2 != "200"' "$out" | wc -l | tr -d ' ')
log "Traffic during the drills: $total requests, $errors non-200"
echo "  responses per pod:"; awk '$2 == "200" {print $3}' "$out" | sort | uniq -c | sed 's/^/   /'
if [ "$errors" -gt 0 ]; then
  echo "  failed requests:"; awk '$2 != "200"' "$out" | head -n 10 | sed 's/^/    /'
fi
trap - EXIT

[ "$errors" -le "$MAX_ERRORS" ] || die "$errors failed requests during the drills (allowed: $MAX_ERRORS)"
ok "Service stayed available through a spot reclaim and an on-demand outage, and placement self-healed"
