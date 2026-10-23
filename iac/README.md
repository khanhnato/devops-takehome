# Part 5: IaC designs (validate-only)

Validated by `scripts/50-validate-tf.sh`:
- `terraform fmt -check`, `init -backend=false` and `validate` for Cloudflare;
- `kubeconform -strict` against the Karpenter v1 CRD schemas.

## 5a: Karpenter for GPU inference ([`karpenter/gpu-inference.yaml`](karpenter/gpu-inference.yaml))

Uses the current stable API (`karpenter.sh/v1` NodePool, `karpenter.k8s.aws/v1` EC2NodeClass), checked against the upstream docs for Karpenter v1.14.

| Requirement | How it is met |
|---|---|
| Spot preferred, on-demand fallback | Two NodePools sharing one EC2NodeClass: `gpu-spot` (`weight: 100`) and `gpu-on-demand` (`weight: 10`). When spot GPU capacity is unavailable, the pods fall through to the lower-weight pool. |
| GPU taint | `nvidia.com/gpu=true:NoSchedule` on both pools, so only workloads that tolerate it land there. |
| Don't kill inference mid-request | `consolidationPolicy: WhenEmpty` + `consolidateAfter: 10m`: a busy GPU node is never repacked to save money. |
| | Budgets: at most 10% of nodes disrupted at once, and no drift replacement during business hours. |
| | `terminationGracePeriod: 30m` lets in-flight requests drain. |
| | Long-lived model servers can add `karpenter.sh/do-not-disrupt: "true"`. |
| Sensible limits | `nvidia.com/gpu` caps of 16 (spot) and 8 (on-demand), plus CPU/memory limits. The on-demand fallback is bounded because it costs ~3x more. |

### Spot vs on-demand for AI inference

Spot GPUs are typically 60–70% cheaper than on-demand. That is a big saving, because GPU nodes dominate the cost of an inference platform, but it comes with risks:
- **Interruptions:** spot nodes can be reclaimed with a 2-minute notice. A model server must then drain in-flight requests and the replacement must reload the model, often several GB, which takes tens of seconds to minutes. That reload time is where latency and availability are lost.
- **Capacity:** GPU spot capacity is also scarcer and more correlated (a whole instance family can disappear in a region at once), so a fallback is mandatory.

The trade-off therefore depends on the workload:
- **Stateless, horizontally scaled, latency-tolerant inference** (batch or async, or real-time behind enough replicas): spot-first, as in this design. Diversify across several GPU families and sizes and keep N+1 replicas. Requests must be idempotent or retried. Give pods a `terminationGracePeriodSeconds` that fits the 2-minute notice.
- **Strict latency SLOs, long-running single requests, or large models with slow cold starts:** keep a baseline of on-demand (or reserved / Savings Plan) capacity sized for steady-state traffic, and let spot absorb bursts.

In practice that is two pools, as here, plus a PodDisruptionBudget and capacity-type spread on the inference Deployment, so that at least one replica stays on on-demand. This is the same pattern Part 2 uses for the CPU service.

## 5b: Cloudflare ([`cloudflare/`](cloudflare/))

- **Proxied record:** a proxied `CNAME` record for `quote-api.example.com`, with TTL 1 (automatic, which proxied records require).
- **Cache rules:** one `http_request_cache_settings` ruleset, which is the single entry point per zone and phase.
  - Rule 1 bypasses the cache for `/api/*`.
  - Rule 2 caches static asset extensions aggressively: 30 days at the edge, overriding the origin, and 1 day in browsers.
- **Adopting a manual record:** an `import` block adopts the manually created `www.example.com` record (`id = "<zone_id>/<record_id>"`, Cloudflare provider v5 format).
- **Credentials:** only via `CLOUDFLARE_API_TOKEN`, a scoped token, never in code. Remote state with locking is noted for prod.
