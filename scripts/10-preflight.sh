#!/usr/bin/env bash
# Preflight: check that the lab is healthy before any task runs.
# run-all.sh calls it first; run it alone any time to ask "is my lab ready?".
# Each check waits (bounded) because some components, e.g. Traefik, are
# installed asynchronously by k3s and become ready a minute or two after the
# bootstrap has finished.
source "$(dirname "$0")/lib/common.sh"
wait_for_bootstrap

TIMEOUT="${PREFLIGHT_TIMEOUT:-300}"   # seconds to wait for each check
failed=0

# check <description> <function> [warn]
# Retries <function> until it succeeds or TIMEOUT expires; prints its last
# output as the detail. With "warn", a failure is reported but not fatal.
check() {
  local desc=$1 fn=$2 mode=${3:-fail} out="" deadline=$((SECONDS + TIMEOUT)) waited=0
  until out="$($fn 2>&1)"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      if [ "$mode" = warn ]; then
        printf '  %s[WARN]%s %-38s %s\n' "$(_c '1;33')" "$(_c 0)" "$desc" "$out"
      else
        printf '  %s[FAIL]%s %-38s %s\n' "$(_c '1;31')" "$(_c 0)" "$desc" "$out"
        failed=$((failed + 1))
      fi
      return 0
    fi
    [ "$waited" = 0 ] && printf '  [....] %-38s waiting (up to %ss): %s\n' "$desc" "$TIMEOUT" "$out"
    waited=1
    sleep 5
  done
  printf '  %s[ OK ]%s %-38s %s\n' "$(_c '1;32')" "$(_c 0)" "$desc" "$out"
}

api_server() {
  kubectl version -o json | jq -r '"server " + .serverVersion.gitVersion'
}

nodes_ready() {
  local total ready
  total=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
  ready=$(kubectl get nodes --no-headers | awk '$2 == "Ready"' | wc -l | tr -d ' ')
  echo "$ready/$total Ready (need 1 server + 4 agents)"
  [ "$total" -ge 5 ] && [ "$ready" -eq "$total" ]
}

nodepools() {
  local spot od gpu taint
  spot=$(kubectl get nodes -l acme.io/capacity=spot --no-headers | wc -l | tr -d ' ')
  od=$(kubectl get nodes -l acme.io/capacity=on-demand --no-headers | wc -l | tr -d ' ')
  gpu=$(kubectl get nodes -l acme.io/node-type=gpu -o name | head -n1)
  taint=$(kubectl get "${gpu:-node/none}" -o jsonpath='{.spec.taints[?(@.key=="nvidia.com/gpu")].effect}' 2>/dev/null)
  echo "spot=$spot on-demand=$od gpu=${gpu#node/} taint=${taint:-none}"
  [ "$spot" -ge 2 ] && [ "$od" -ge 1 ] && [ -n "$gpu" ] && [ "$taint" = NoSchedule ]
}

# deploy_available <namespace> <name> <min-available>
deploy_available() {
  local avail want
  read -r want avail <<<"$(kubectl -n "$1" get deploy "$2" -o jsonpath='{.spec.replicas} {.status.availableReplicas}' 2>/dev/null)"
  echo "${avail:-0}/${want:-?} available"
  [ "${avail:-0}" -ge "$3" ]
}
coredns()        { deploy_available kube-system coredns 1; }
metrics_server() { deploy_available kube-system metrics-server 1; }
traefik()        { deploy_available kube-system traefik 2; }

metrics_api() {
  kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null || { echo "not serving yet"; return 1; }
  echo "serving node metrics (HPA can scale)"
}

ingress() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$INGRESS_URL/")
  # Any HTTP answer means Traefik is serving (404 = no route for "/", e.g. app not deployed yet).
  echo "HTTP $code at / (host: http://localhost:${HTTP_PORT})"
  [ "$code" != "000" ]
}

# egress <url>: reachable = any HTTP answer (ghcr.io/v2/ answers 401 without a token).
egress() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1")
  echo "HTTP $code"
  [ "$code" != "000" ]
}
egress_github() { egress https://github.com; }
egress_ghcr()   { egress https://ghcr.io/v2/; }

log "Preflight: checking the lab before running tasks"
check "Kubernetes API server"               api_server
check "Nodes Ready"                         nodes_ready
check "Nodepools labeled + GPU tainted"     nodepools
check "CoreDNS"                             coredns
check "metrics-server"                      metrics_server
check "Metrics API (for HPA)"               metrics_api
check "Traefik ingress (2 replicas, HA)"    traefik
check "Ingress answering"                   ingress
# Argo CD clones the chart from GitHub and kubelet pulls the app from GHCR.
TIMEOUT=15 check "Egress to github.com"     egress_github warn
TIMEOUT=15 check "Egress to ghcr.io"        egress_ghcr   warn

[ "$failed" -eq 0 ] || die "preflight: $failed check(s) failed (see above). Lab not ready; tasks not started."
ok "Lab is healthy and ready for the tasks"
