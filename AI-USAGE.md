# AI usage disclosure

## Tools and where they were used

| Tool | Used for |
|---|---|
| **Claude Code** (Claude Opus, in VS Code) | Explaining the brief; scaffolding the repo (Go service, Dockerfiles, Helm chart, scripts, workflow, Terraform, Karpenter YAML); debugging on the live cluster; first drafts of the docs. |
| Verification tooling (not AI) | `go vet`/`go test -race`, `helm lint` + `helm template`, `kubeconform -strict` (k8s 1.35 + Karpenter v1 CRD schemas), `terraform fmt/validate`, Semgrep 1.182.0, shellcheck, live release lookups, and the k3d cluster itself. |

**How I worked:** the AI drafts, and nothing stays in the repo until it is verified against a tool, the upstream docs, or a live run.
- Versions were pinned from live release data, not from memory: k3s/kubectl 1.35.9, Argo CD chart 10.10.5, Cloudflare provider 5.28, Karpenter v1.14 docs, and GitHub Actions by commit SHA.
- The most useful thing I did was **question the output**. Each of the prompts below exposed a real bug.

## Representative prompts that moved things forward

I wrote these prompts in Vietnamese; they are translated below.

1. *"Check the brief for me: when the reviewer runs `scripts/run-all.sh`, are we required to have it install the tools it needs on their machine?"*
   - The answer was no: tools live in the toolbox, and the host only needs Docker.
   - Re-reading the host-side code to answer it exposed a **crash on macOS's bash 3.2**. An empty array expanded under `set -u` (`tty[@]: unbound variable`) would have killed `./scripts/run-all.sh` for any Mac reviewer running it in a terminal.
   - Reproduced with `/bin/bash` 3.2, then fixed.
2. *"When `docker compose up -d` finishes it prints that everything is started … the reviewer will think it's done and start testing, which can easily be mistaken for a failure."*
   (The cluster was in fact still bootstrapping at that point.)
   - I had hit exactly that myself: `curl` gave `Empty reply from server`.
   - This led to the `cluster-ready` gate service: `up -d` now blocks until the toolbox healthcheck passes, and fails fast if the bootstrap fails.
3. *"I want `run-all.sh` to also include a healthy/ready check, so the reviewer knows the state before the tests run."*
   - This produced `10-preflight.sh`.
   - Testing it with `PREFLIGHT_TIMEOUT=10` exposed that **host environment variables never reached the toolbox**, so documented knobs like `MAX_ERRORS=2` had silently done nothing (see 7 below).

## Where the AI was wrong or suboptimal, and how it was caught

1. **Wrong claim about secret scanning.** The first draft of `MIGRATION-NOTES.md` said the legacy file's AWS keys are "correctly flagged by `p/secrets`".
   - Running Semgrep 1.182.0 with `p/secrets` on the file gave **0 findings**, probably because they are AWS's well-known `…EXAMPLE` keys.
   - Corrected, and recorded as a gap: SAST is not secret scanning, so gitleaks and push protection belong in a separate gate.
2. **Invalid YAML.** The Karpenter draft shared a `disruption:` block between two NodePools via a YAML anchor. Anchors don't cross `---` document boundaries, so the file would not parse.
   Rewritten explicitly and validated with `kubeconform -strict` against the Karpenter v1 schemas.
3. **Wrong Docker-socket advice.** The README told Colima users to set `DOCKER_SOCK=$HOME/.colima/default/docker.sock`.
   A bind-mount source is resolved by the daemon inside the VM, where the default `/var/run/docker.sock` is correct. Caught while setting up Colima on my Intel Mac (macOS 13, where Docker Desktop is no longer supported).
4. **A troubleshooting write-up that guessed.** The first `TROUBLESHOOTING.md` was drafted from reading the manifests. Replaying the fixes one at a time on the cluster showed it was wrong twice:
   - **Fault order:** the bad image tag only surfaces *after* the ConfigMap fix, because kubelet mounts volumes before pulling images.
   - **Smoke-test error:** the Job failed with `curl: (7) Couldn't connect`, not the predicted DNS error.

   A long-lived probe pod then confirmed that DNS *is* blocked. The Job had slipped past DNS because kube-router isolates new pods a moment after start.
   The document now contains only captured output.
5. **A placement guarantee that wasn't one.** The README claimed the spread constraint keeps "at least one replica on on-demand".
   - Draining the on-demand node and uncordoning it showed all 3 replicas **stayed on spot**: topology spread is only evaluated at scheduling time.
   - Fixed by adding the descheduler (topology-spread plugin only), and the drill now proves the recovery (phase 2 of `25-reclaim-drill.sh`).
6. **Unmeasured numbers and a missed requirement.**
   - The README said the image was "~10 MB"; measured, it is 18.7 MB.
   - A full re-read of the brief found that Part 5a's required paragraph on spot vs on-demand for AI inference existed only as YAML comments. It is now in `iac/README.md`.
7. **Host env vars silently ignored.** `docker compose exec` does not forward the host environment, so `MAX_ERRORS=2 ./scripts/25-…` never took effect.
   Found via prompt 3 above; fixed by forwarding an explicit allow-list with `exec -e`.
8. **The SAST gate failed on its first local run**, on `math/rand` in the app and the toolbox running as root. This was expected, and good.
   Each finding was triaged with an inline, justified `nosemgrep` instead of disabling rules repo-wide (see `MIGRATION-NOTES.md`).
9. **This file itself.** An earlier AI draft of this disclosure listed a prompt I never sent, and credited me with instructions I never gave.
   I caught it when I asked for every Markdown file to be checked against what actually happened, and rewrote the file from the real session.

## What I ran into myself

- **My machine can't run Docker Desktop.** It is an Intel Mac on macOS 13, which current Docker Desktop no longer supports, and Homebrew has no prebuilt bottles for it either.
  I installed Colima, Lima, the Docker CLI, compose, buildx and gh from their official release binaries, after checking each one's SHA-256.
  Because I used Colima, I tested the repo on a Docker setup other than the "default" one, which is how the socket-path mistake (3 above) surfaced.
- **Docker Hub timed out** (`TLS handshake timeout`) during my first `docker compose up -d`, so the k3d cluster creation failed and left a stray network behind.
  A reviewer on a slow network would hit the same thing. The bootstrap now pre-pulls images with retries and cleans up leftovers, and teardown leaves the cluster network before deleting.
- **I tested too early, then skipped a step.** After `docker compose up -d` said `Started`, I curled right away and got `Empty reply from server`. On the next fresh run I didn't run `run-all.sh` at all, and wondered why there was no `argocd` namespace.
  Both were my mistakes, but a reviewer following the brief literally could make them too. That is why `up -d` now waits for a healthy cluster and says what to run next, and why `run-all.sh` starts with a preflight table.
- **I treated "it ran once" as not enough.** Before committing, I wiped Docker completely (0 containers, images, volumes and networks) and re-ran exactly the reviewer's two commands from the local code.
  After pushing, I ran them again from a fresh `git clone` of the public repo.
