#!/usr/bin/env bash
# Part 2: install Argo CD and deploy quote-api through an Argo CD Application
# that syncs charts/quote-api from this Git repository. Idempotent.
source "$(dirname "$0")/lib/common.sh"
wait_for_bootstrap

ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.10.5}"   # Argo CD v3.5.5

# --- Which repo should Argo CD sync? Default: this clone's origin remote.
if [ -z "${REPO_URL:-}" ]; then
  REPO_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  # git@github.com:owner/repo.git -> https://github.com/owner/repo.git (public, no creds needed)
  REPO_URL="$(echo "$REPO_URL" | sed -E 's#^git@([^:]+):#https://\1/#')"
fi
[ -n "$REPO_URL" ] || die "no git 'origin' remote found; run with REPO_URL=https://github.com/<owner>/<repo>.git"
REVISION="${REVISION:-HEAD}"

log "Installing Argo CD (chart $ARGOCD_CHART_VERSION)"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --values "$REPO_ROOT/argocd/values.yaml" \
  --wait --timeout 10m

log "Applying Application quote-api -> $REPO_URL @ $REVISION (charts/quote-api)"
sed -e "s#__REPO_URL__#${REPO_URL}#" -e "s#__REVISION__#${REVISION}#" \
  "$REPO_ROOT/argocd/quote-api-app.yaml" | kubectl apply -f -
# Ask Argo CD to re-read Git now instead of waiting for the next poll.
kubectl -n argocd annotate application quote-api argocd.argoproj.io/refresh=normal --overwrite >/dev/null

log "Waiting for the Application to be Synced + Healthy"
status=""
for _ in $(seq 1 90); do
  status="$(kubectl -n argocd get application quote-api \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  [ "$status" = "Synced/Healthy" ] && break
  sleep 5
done
if [ "$status" != "Synced/Healthy" ]; then
  warn "Application status: ${status:-unknown}"
  kubectl -n argocd get application quote-api -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' || true
  kubectl -n "$APP_NS" get pods -o wide || true
  die "quote-api did not become healthy (image pushed to GHCR and public? see README troubleshooting)"
fi
ok "Application quote-api is Synced/Healthy"

log "Placement (expect 2 x spot + 1 x on-demand, none on gpu)"
assert_placement

log "Smoke test through the ingress"
retry 30 2 curl -fsS --max-time 5 "$INGRESS_URL/api/quote" || die "ingress did not answer"
echo
ok "Deployed. From your host:  curl http://localhost:${HTTP_PORT}/api/quote"
echo "     Argo CD UI: http://localhost:${ARGOCD_PORT}  (user: admin, password: \
$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '<n/a>'))"
