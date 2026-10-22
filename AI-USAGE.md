# AI usage disclosure

## Tools and where they were used

| Tool | Used for |
|---|---|
| **Claude Code** (Claude Opus, in VS Code) | Reading and explaining the brief; scaffolding the repo (Go service, Dockerfiles, Helm chart, scripts, workflow, Terraform, Karpenter YAML); first drafts of the docs. |
| Local verification tooling (not AI) | `go vet`/`go test -race`, `helm lint` + `helm template`, `kubeconform -strict` (k8s 1.35 + Karpenter v1 CRD schemas), `terraform fmt/validate`, Semgrep 1.182.0, live lookups of current release versions. |

How I worked: the AI drafts, and then I verify every claim against a tool, the upstream docs, or a live cluster before it stays in the repo.
Anything I couldn't verify yet is marked as such (for example the TODO at the top of `TROUBLESHOOTING.md`).

## Representative prompts that moved things forward

1. *"Đọc file ASSIGNMENT - DevOps.md và giải thích yêu cầu trong đó cho tôi"* ("read the assignment and explain the requirements to me").
   Produced a structured breakdown of the brief, and flagged early that the provided files might be intentionally imperfect and that `run-all.sh` is mine to write.
2. *"Giờ hãy tạo giúp tôi 1 repo theo đúng yêu cầu, trước mắt để local đã"* ("now create a repo that meets the requirements, local only for now").
   This is the scaffolding run. I asked it to pin current versions by checking live sources, and to validate everything that can be validated without a cluster.
3. Follow-up on the placement policy: *"why maxSkew 1 and not 2? what happens to the spread constraint when a node is cordoned during the drill?"*
   This led to `nodeTaintsPolicy: Honor` and the written reasoning in the chart and README.

## Where the AI was wrong or suboptimal, and how it was caught

1. **Wrong claim about secret scanning.** The first draft of `MIGRATION-NOTES.md` said the legacy file's AWS keys are "correctly flagged by `p/secrets`".
   - Caught by actually running Semgrep 1.182.0 with `p/secrets` against `ci/legacy.gitlab-ci.yml`: **0 findings**, probably because they are AWS's well-known `…EXAMPLE` keys.
   - Fixed the doc and recorded it as a gap: SAST is not secret scanning, so gitleaks and push protection would be a separate gate.
2. **Invalid YAML in the Karpenter manifests.** The draft shared the `disruption:` block between the two NodePools with a YAML anchor (`&gpu-disruption` / `*gpu-disruption`).
   - Anchors don't cross `---` document boundaries, so the file would not even parse.
   - Caught on review, rewritten explicitly, then validated with `kubeconform -strict` against the Karpenter v1 CRD schemas.
3. **Outdated versions from memory.** Left alone, the AI's defaults were roughly a year old (kubectl/k3s 1.31, Argo CD chart 7.x, Cloudflare provider v4 resource names).
   - I made it look up current releases (k3s/kubectl 1.35.9, Argo CD chart 10.10.5 / v3.5.5, Cloudflare provider 5.28, Karpenter v1.14 docs) and pin them.
   - GitHub Actions are pinned by commit SHA, not tag.
4. **Wrong Docker-socket advice for Colima.** The README's troubleshooting table told Colima users to set `DOCKER_SOCK=$HOME/.colima/default/docker.sock`.
   - That is backwards: a bind-mount source is resolved by the daemon inside the Colima VM, where the socket is `/var/run/docker.sock`.
   - Caught when setting up Colima on my own Intel Mac (macOS 13, where Docker Desktop is no longer supported). `docker run -v /var/run/docker.sock:...` worked with the default, so I corrected the row.
5. **The SAST gate failed on the first run** with `math/rand` in the app and the toolbox running as root.
   - Rather than accept a blanket rule disable, each finding was triaged individually with an inline justification (see `MIGRATION-NOTES.md`).

<!-- TODO (author): add what you hit yourself when running the stack end-to-end on a real Docker host,
     e.g. anything the scaffold got wrong about k3d networking, Traefik HA, NetworkPolicy + kubelet probes, or GHCR visibility. -->
