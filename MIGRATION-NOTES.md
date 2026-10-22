# Part 4: GitLab CI → GitHub Actions migration notes

Source: [`ci/legacy.gitlab-ci.yml`](ci/legacy.gitlab-ci.yml). Result: [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
I migrated the **intent** (test → build → deploy for quote-api), not the file.

## What changed and why

| Legacy (GitLab) | Problem | Now (GitHub Actions) |
|---|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` hard-coded in `variables:` | Credentials in Git: anyone with read access has them forever, rotation needs a commit, and they show up in forks and logs. (These were AWS's documentation example values; I **redacted** them in `ci/legacy.gitlab-ci.yml` before the first commit so no credential-shaped string ever enters this repo's history.) | **No static cloud credentials at all.** GHCR uses the short-lived `GITHUB_TOKEN`, and cosign uses OIDC keyless signing. Anything that needs AWS later uses OIDC → `aws-actions/configure-aws-credentials` with an IAM role scoped to this repo + branch. |
| `sonar_check` with `allow_failure: true`, only on `master` | A quality gate that can never fail is decoration. It also ran only after merge, when it is too late to block anything. | `sast` job: **Semgrep** (`p/golang`, `p/dockerfile`, `p/github-actions`, `p/secrets`) with `--error`, on every PR and push. A finding fails the job, and `image` `needs:` it, so nothing gets built or published past a finding. |
| `sonar-scanner-cli:4.6`, `node:16`, `docker:20.10`, `kubectl:1.24` | EOL or unpatched toolchains; floating tags make builds non-reproducible. | Current pinned versions: Semgrep 1.182.0, Trivy 0.76.0, and every third-party action pinned by **commit SHA** with the version in a comment, since tags can be moved, as the tj-actions incident showed. |
| `npm test \|\| echo "tests flaky, continuing"` | Swallows test failures, so the pipeline is always green. | `go vet` + `go test -race` with no escape hatch. A flaky test gets fixed or quarantined explicitly, not silently ignored. |
| Pipeline only runs on `master` | No feedback on merge requests. | Lint, test and SAST run on every `pull_request`. Publishing and deploy run only on `main`. |
| `docker build -t $IMAGE:latest` + push | `latest` is mutable: you cannot tell what is running, and rollback is impossible. | Tag = **full git SHA** (plus `latest` as a non-deployed alias). Multi-arch (amd64 + arm64), OCI labels link the image to the commit and repo. |
| No image scanning | Vulnerable base images or dependencies ship silently. | Build → **Trivy gate** (`HIGH,CRITICAL`, `--ignore-unfixed`, exit code 1) **before** push. A failing scan means nothing is published. |
| No signing | No provenance. | **cosign keyless** signature on the pushed digest (Sigstore, GitHub OIDC identity). Can be enforced in-cluster with Kyverno / policy-controller. |
| `deploy_prod`: `kubectl set image ... :latest` using a kubeconfig from a CI variable, `when: manual` | Push-based deploy: CI holds cluster-admin-ish credentials, the cluster drifts from Git, and `:latest` cannot be rolled back. | **GitOps:** the `deploy` job commits the new SHA to `charts/quote-api/values.yaml` (`[skip ci]`), and Argo CD reconciles it. Rollback is `git revert`. CI has **no** cluster credentials. The manual gate becomes a GitHub Environment with required reviewers if needed. |
| `docker:dind` service | Privileged Docker-in-Docker on shared runners. | BuildKit via `docker/setup-buildx-action` with the GHA cache. |
| — | — | `concurrency` cancels superseded PR runs. Default `permissions: contents: read`, and each job elevates only what it needs (`packages: write`, `id-token: write`, `contents: write`). |

## Migrating GitLab CI variables and secrets for a real project

1. **Inventory first.** Export the project, group and instance-level CI/CD variables (API `GET /projects/:id/variables`, `/groups/:id/variables`). Classify each one:
   - config: non-secret
   - secret: still needed
   - credential replaceable by OIDC
   - dead
2. **Kill what OIDC can replace.** AWS keys, kubeconfigs and registry passwords get no migration at all:
   - AWS: an IAM role trusting `token.actions.githubusercontent.com`, with `sub` restricted to `repo:org/quote-api:ref:refs/heads/main` (or an environment).
   - Registry: GHCR via `GITHUB_TOKEN`.
   - Cluster deploys: GitOps, so CI needs no kubeconfig.
3. **Map the rest to the right GitHub scope:**
   - GitLab *protected* variables → **Environment secrets** on a `production` environment with required reviewers and a `main`-only branch policy. This is the equivalent of protected-branch-only variables.
   - Group variables → **Organization secrets** restricted to selected repositories.
   - Non-secret config → `vars.*` (Actions variables), not secrets.
   - *Masked* has no equivalent to migrate: GitHub masks every secret automatically. *File*-type variables become base64-encoded secrets that a step decodes.
4. **Rotate on migration.** Every secret that existed in GitLab is considered exposed to the old system. Issue new values directly into GitHub (or into AWS Secrets Manager and fetch them at runtime), then revoke the old ones.
   The hard-coded keys in the legacy file get revoked and the commit history scanned (`gitleaks`), because removing them from HEAD doesn't remove them from history.
5. **Automate and verify.** Write secrets with `gh secret set --env production ...` from a script that reads them from the vault, never pasting by hand. Run both pipelines in parallel for a sprint, compare artifacts, then make GitLab read-only.

## How the hard-failing gate was verified

- The gate is real because `semgrep scan --error` exits 1 on any finding, the job has no `continue-on-error`, and `image` lists it under `needs:`.
- Before pushing, I ran the same Semgrep version (1.182.0) and rulesets locally. **The first run failed with 2 blocking findings**, which shows the gate actually bites:
  - `math-random-used` in `app/main.go`: `math/rand` picks which quote to return, which has no security impact. Triaged as a false positive with an inline `nosemgrep` and a reason, rather than disabling the rule for the whole repo.
  - `missing-user-entrypoint` in `toolbox/Dockerfile`: the toolbox must run as root to drive the host Docker socket, whose group id differs per host. It is a local dev tool, never deployed, so the risk is accepted with an inline `nosemgrep` and a comment.

  The app image itself runs as UID 65532 and is not exempted.
- The provided inputs `troubleshoot/broken-app.yaml` and `ci/legacy.gitlab-ci.yml` are excluded in `.semgrepignore`. They are kept verbatim as assignment artifacts, not code we ship.
- **Gap found while verifying:** before redaction, `p/secrets` did **not** flag the AWS keys in the legacy file, most likely because they are AWS's well-known `…EXAMPLE` values. So the SAST gate is not a secret-scanning gate.
  For real secret scanning I would add `gitleaks` (full history) as a separate blocking job, plus GitHub push protection.
- To see the gate fail, add something like `exec.Command("sh", "-c", r.URL.Query().Get("cmd"))` to `app/main.go` in a PR.
