#!/usr/bin/env bash
# Part 3: apply the fixed troubleshooting manifests and run the provided
# verifier. Pass --from-broken to first apply broken-app.yaml and see it fail.
source "$(dirname "$0")/lib/common.sh"
wait_for_bootstrap

TS="$REPO_ROOT/troubleshoot"

if [ "${1:-}" = "--from-broken" ]; then
  log "Applying the original broken-app.yaml"
  kubectl apply -f "$TS/broken-app.yaml"
  sleep 20
  kubectl -n troubleshoot get pods -o wide || true
  sh "$TS/verify.sh" || warn "verify.sh fails on the broken manifests, as expected"
fi

log "Applying troubleshoot/fixed-app.yaml"
kubectl apply -f "$TS/fixed-app.yaml"
# Let the Deployments roll; verify.sh only waits 60s per Deployment.
kubectl -n troubleshoot rollout status deploy/web --timeout=300s
kubectl -n troubleshoot rollout status deploy/ai-inference --timeout=300s
kubectl -n troubleshoot get pods -o wide

log "Running troubleshoot/verify.sh"
sh "$TS/verify.sh"
