#!/usr/bin/env bash
# Run every task in order. Safe to re-run.
#   docker compose up -d && ./scripts/run-all.sh
source "$(dirname "$0")/lib/common.sh"
wait_for_bootstrap

for s in 10-preflight.sh 20-deploy.sh 25-reclaim-drill.sh 30-troubleshoot.sh 50-validate-tf.sh; do
  echo
  log "################ $s ################"
  "$REPO_ROOT/scripts/$s"
done

echo
ok "All tasks completed."
echo "     App:     curl http://localhost:${HTTP_PORT}/api/quote"
echo "     Argo CD: http://localhost:${ARGOCD_PORT}"
