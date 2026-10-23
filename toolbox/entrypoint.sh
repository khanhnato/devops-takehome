#!/usr/bin/env bash
# Toolbox entrypoint: bootstrap the k3d cluster, then stay alive for `exec`.
# `docker compose up -d` waits for the healthcheck (bootstrap.status = ok).
set -uo pipefail

echo running > /tmp/bootstrap.status
if /workspace/scripts/00-cluster-up.sh 2>&1 | tee /tmp/bootstrap.log; then
  echo ok > /tmp/bootstrap.status
else
  echo failed > /tmp/bootstrap.status
  echo "Bootstrap FAILED (log above). Fix the cause, then run: docker compose up -d" >&2
  # Exit so `docker compose up -d` fails fast with "dependency failed to start".
  exit 1
fi

exec sleep infinity
