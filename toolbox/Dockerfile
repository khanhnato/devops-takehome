# Toolbox: every CLI the scripts need, pinned. Built locally by docker compose.
FROM alpine:3.23

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.35.9
ARG HELM_VERSION=v3.22.1
ARG TERRAFORM_VERSION=1.15.7
ARG K6_VERSION=v2.3.0
ARG K3D_VERSION=v5.9.0
ARG KUBECONFORM_VERSION=v0.8.0

RUN apk add --no-cache bash curl jq git ca-certificates docker-cli unzip coreutils

RUN set -eux; \
    arch="${TARGETARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" | tar xz -C /usr/local/bin --strip-components=1 "linux-${arch}/helm"; \
    curl -fsSLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip"; \
    unzip -o /tmp/tf.zip terraform -d /usr/local/bin; rm /tmp/tf.zip; \
    curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${arch}.tar.gz" | tar xz -C /usr/local/bin --strip-components=1 "k6-${K6_VERSION}-linux-${arch}/k6"; \
    curl -fsSLo /usr/local/bin/k3d "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${arch}"; \
    curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${arch}.tar.gz" | tar xz -C /usr/local/bin kubeconform; \
    chmod +x /usr/local/bin/*; \
    kubectl version --client; helm version --short; terraform version; k6 version; k3d version; kubeconform -v

# The repo is bind-mounted with the host user's uid; let git read it.
RUN git config --global --add safe.directory '*'

COPY entrypoint.sh /entrypoint.sh
ENV IN_TOOLBOX=1 KUBECONFIG=/root/.kube/config
WORKDIR /workspace
# Healthy once the cluster bootstrap succeeded; ~30 min budget for cold image pulls.
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=360 \
  CMD [ "$(cat /tmp/bootstrap.status 2>/dev/null)" = "ok" ]
# Root on purpose: the toolbox drives the host Docker socket (k3d) whose group id
# differs per host. Local dev tool only, never deployed.
# nosemgrep: dockerfile.security.missing-user-entrypoint.missing-user-entrypoint
ENTRYPOINT ["/entrypoint.sh"]
