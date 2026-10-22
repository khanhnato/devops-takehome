#!/usr/bin/env bash
# Toolbox entrypoint: bootstrap the k3d cluster in the background of
# `docker compose up -d`, record the outcome, then stay alive for `exec`.
set -uo pipefail

echo running > /tmp/bootstrap.status
if /workspace/scripts/00-cluster-up.sh 2>&1 | tee /tmp/bootstrap.log; then
  echo ok > /tmp/bootstrap.status
else
  echo failed > /tmp/bootstrap.status
  echo "Bootstrap FAILED. See 'docker compose logs toolbox'." >&2
fi

exec sleep infinity
