#!/usr/bin/env bash
# Delete the k3d cluster. `docker compose down` alone does not: the cluster
# nodes are sibling containers created through the Docker socket.
# Afterwards: docker compose down
# Works even when the toolbox has stopped (e.g. after a failed bootstrap).
TOOLBOX_RUN_OK=1 source "$(dirname "$0")/lib/common.sh"

log "Deleting k3d cluster '$CLUSTER_NAME'"
# Leave the cluster network first, otherwise k3d cannot remove it.
docker network disconnect "k3d-${CLUSTER_NAME}" "$(hostname)" >/dev/null 2>&1 || true
k3d cluster delete "$CLUSTER_NAME"   # no-op if it does not exist
echo failed > /tmp/bootstrap.status   # other scripts must not run against a deleted cluster
ok "Cluster deleted. Now run: docker compose down"
