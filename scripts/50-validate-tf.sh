#!/usr/bin/env bash
# Part 5: validate-only checks for the IaC designs.
#   - Cloudflare Terraform: fmt -check, init -backend=false, validate
#   - Karpenter manifests: strict schema validation against the v1 CRDs
source "$(dirname "$0")/lib/common.sh"

TF_DIR="$REPO_ROOT/iac/cloudflare"
# Keep provider downloads out of the bind-mounted repo.
export TF_DATA_DIR=/tmp/tf-data

log "terraform fmt -check ($TF_DIR)"
terraform -chdir="$TF_DIR" fmt -check -recursive -diff

log "terraform init -backend=false"
terraform -chdir="$TF_DIR" init -backend=false -input=false -no-color >/dev/null

log "terraform validate"
terraform -chdir="$TF_DIR" validate

log "Karpenter NodePool/EC2NodeClass against the karpenter.sh/v1 + karpenter.k8s.aws/v1 schemas"
kubeconform -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  "$REPO_ROOT/iac/karpenter/"

ok "IaC validation passed"
