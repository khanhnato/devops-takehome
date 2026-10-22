#!/usr/bin/env bash
# Part 2: simulate a spot reclaim. Drain a spot node that runs a quote-api
# replica while a curl loop hits the ingress, show the pods rescheduling,
# check the placement policy still holds, then uncordon. Idempotent.
source "$(dirname "$0")/lib/common.sh"
wait_for_bootstrap

MAX_ERRORS="${MAX_ERRORS:-0}"
SEL=app.kubernetes.io/name=quote-api

kubectl -n "$APP_NS" get deploy quote-api >/dev/null 2>&1 || die "quote-api is not deployed; run scripts/20-deploy.sh first"

# A previous interrupted run may have left a node cordoned.
for n in $(kubectl get nodes -l acme.io/capacity=spot -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{" "}{end}'); do
  warn "uncordoning $n left over from a previous run"; kubectl uncordon "$n"
done
kubectl -n "$APP_NS" rollout status deploy/quote-api --timeout=180s

log "Placement before the drill"
show_placement

# Victim: a spot node that currently hosts a replica.
victim="$(kubectl -n "$APP_NS" get pods -l "$SEL" -o json | jq -r '.items[].spec.nodeName' | sort -u \
  | grep -Fx -f <(kubectl get nodes -l acme.io/capacity=spot -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') \
  | head -n1 || true)"
[ -n "$victim" ] || die "no quote-api replica on a spot node; nothing to reclaim"

out="$(mktemp)"
cleanup() {
  [ -n "${loop_pid:-}" ] && kill "$loop_pid" 2>/dev/null || true
  kubectl uncordon "$victim" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Starting traffic: curl loop against $INGRESS_URL/api/quote"
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

log "Reclaiming spot node $victim (kubectl drain)"
start=$(date +%s)
kubectl drain "$victim" --ignore-daemonsets --delete-emptydir-data --timeout=180s

log "Waiting until every replica is Ready again"
ready=0 want=1
for _ in $(seq 1 90); do
  read -r want ready <<<"$(kubectl -n "$APP_NS" get deploy quote-api -o jsonpath='{.spec.replicas} {.status.readyReplicas}')"
  ready="${ready:-0}"
  [ "$ready" -ge "$want" ] && break
  sleep 2
done
[ "$ready" -ge "$want" ] || die "only $ready/$want replicas became ready after the drain"
ok "$ready/$want replicas ready, $(( $(date +%s) - start ))s after the drain started"
sleep 3   # a little traffic on the new layout
kill "$loop_pid"; loop_pid=""

log "Scheduling events (pods rescheduled away from $victim)"
kubectl -n "$APP_NS" get events --field-selector reason=Scheduled --sort-by=.lastTimestamp \
  -o custom-columns=TIME:.lastTimestamp,POD:.involvedObject.name,MESSAGE:.message | tail -n 6

log "Placement after the drill"
assert_placement
kubectl -n "$APP_NS" get pods -l "$SEL" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | grep -qx "$victim" && die "a replica is still on the drained node $victim"

total=$(wc -l <"$out" | tr -d ' ')
errors=$(awk '$2 != "200"' "$out" | wc -l | tr -d ' ')
log "Traffic during the drill: $total requests, $errors non-200"
echo "  responses per pod:"; awk '$2 == "200" {print $3}' "$out" | sort | uniq -c | sed 's/^/   /'
if [ "$errors" -gt 0 ]; then
  echo "  failed requests:"; awk '$2 != "200"' "$out" | head -n 10 | sed 's/^/    /'
fi

log "Uncordoning $victim (spot capacity is back)"
kubectl uncordon "$victim"
trap - EXIT

[ "$errors" -le "$MAX_ERRORS" ] || die "$errors failed requests during the drill (allowed: $MAX_ERRORS)"
ok "Service stayed available through the spot reclaim"
