#!/usr/bin/env bash
# Create (or start) the local k3d cluster: 1 server + 4 agents, join the
# toolbox to the cluster network, write a kubeconfig, then label/taint the
# nodes with the provided troubleshoot/prepare.sh.
# Runs automatically from the toolbox entrypoint on `docker compose up -d`.
source "$(dirname "$0")/lib/common.sh"

K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.35.9-k3s1}"
AGENTS=4

if k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  log "Cluster '$CLUSTER_NAME' exists, making sure it is started"
  k3d cluster start "$CLUSTER_NAME" --wait
else
  # Pull up front with retries: k3d pulls only once and gives up on the first
  # registry timeout (seen in practice: "TLS handshake timeout" on Docker Hub).
  k3d_tag="$(k3d version | sed -n 's/^k3d version v//p')"
  for img in "$K3S_IMAGE" "ghcr.io/k3d-io/k3d-proxy:${k3d_tag}" "ghcr.io/k3d-io/k3d-tools:${k3d_tag}"; do
    docker image inspect "$img" >/dev/null 2>&1 && continue
    log "Pulling $img"
    retry 5 10 docker pull -q "$img" || die "could not pull $img (network/proxy?)"
  done

  # A failed create can leave its network/volume behind ("FAILED to rollback").
  docker network rm "k3d-${CLUSTER_NAME}" >/dev/null 2>&1 || true
  docker volume rm "k3d-${CLUSTER_NAME}-images" >/dev/null 2>&1 || true

  log "Creating k3d cluster '$CLUSTER_NAME' (1 server + $AGENTS agents, $K3S_IMAGE)"
  # Host ports: $HTTP_PORT -> Traefik ingress, $ARGOCD_PORT -> Argo CD UI NodePort.
  # The extra TLS SAN lets the toolbox reach the API through the k3d load balancer.
  k3d cluster create "$CLUSTER_NAME" \
    --image "$K3S_IMAGE" \
    --servers 1 --agents "$AGENTS" \
    --port "${HTTP_PORT}:80@loadbalancer" \
    --port "${ARGOCD_PORT}:30080@loadbalancer" \
    --k3s-arg "--tls-san=k3d-${CLUSTER_NAME}-serverlb@server:*" \
    --kubeconfig-update-default=false --kubeconfig-switch-context=false \
    --wait --timeout 300s
fi

# Join this container to the cluster's Docker network (idempotent).
self="$(hostname)"
net="k3d-${CLUSTER_NAME}"
if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$self" | grep -q "\"$net\""; then
  log "Connecting toolbox to network $net"
  docker network connect "$net" "$self"
fi

mkdir -p "$(dirname "$KUBECONFIG")"
k3d kubeconfig get "$CLUSTER_NAME" \
  | sed -E "s#server: https://.*#server: https://k3d-${CLUSTER_NAME}-serverlb:6443#" > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"

log "Waiting for the API server and all nodes"
retry 60 2 kubectl get nodes >/dev/null || die "API server not reachable"
retry 60 2 bash -c "[ \$(kubectl get nodes --no-headers | wc -l) -ge $((AGENTS + 1)) ]" \
  || die "expected $((AGENTS + 1)) nodes to register"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# Make the ingress controller survive a node drain: k3s ships Traefik with a
# single replica, which would turn the reclaim drill into an ingress outage.
log "Configuring Traefik for HA (2 replicas, PDB, anti-affinity)"
kubectl apply -f - <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    deployment:
      replicas: 2
    podDisruptionBudget:
      enabled: true
      maxUnavailable: 1
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app.kubernetes.io/name: traefik
EOF

log "Labeling/tainting nodepools with troubleshoot/prepare.sh"
sh "$REPO_ROOT/troubleshoot/prepare.sh"

ok "Cluster '$CLUSTER_NAME' is ready (nodes labeled, ingress up). The app is NOT deployed yet."
echo "    Next: ./scripts/run-all.sh   (then: curl http://localhost:${HTTP_PORT}/api/quote)"
