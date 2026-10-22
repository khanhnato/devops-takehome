# Part 7: Ops answers

## 1. EKS 1.33 → 1.35, zero downtime

The control plane moves **one minor at a time**, so this is two full cycles (→1.34, then →1.35). Each hop:

1. **Pre-flight:**
   - EKS Upgrade Insights + `pluto`/`kubent` for removed APIs.
   - Check every chart and operator (Karpenter, LB controller, Argo CD…) supports the target version.
   - Rehearse on staging.
   - Confirm every prod workload has ≥2 replicas, a PDB and readiness probes.
2. **Control plane:** managed and HA. Nodes one minor behind keep working (kubelet skew is allowed).
3. **Add-ons, in order:** vpc-cni (one minor at a time) → kube-proxy (match the control plane) → CoreDNS (≥2 replicas, PDB) → EBS/EFS CSI (controller, then node DaemonSet).
   Use managed add-ons with `--resolve-conflicts PRESERVE`.
4. **Nodes:** new AMI via Karpenter drift, rate-limited by NodePool disruption budgets, or a managed node group rolling update with surge. Order: system → general → GPU last.
5. **Verify:** SLO dashboards and smoke tests before the next hop.

**Top 3 risks:**
- **Removed APIs** in manifests or charts, which break deploys or controllers.
- **Add-on and version incompatibility** (vpc-cni/CSI): pods get no IPs or volumes don't attach.
- **Node rotation disruption:** missing or over-strict PDBs, single-replica services, zonal EBS volumes without capacity in their AZ.

## 2. Spot reclaims page on-call at 3 AM

**Page on user impact, not on expected events.** A spot reclaim comes with a 2-minute notice, so it is expected.

- Karpenter / Node Termination Handler consume the interruption event and cordon and drain gracefully. Export that as an alert/metric `SpotInterruption{node}`.
- In Alertmanager, add an **inhibit rule**: `KubeNodeUnreachable{node=X}` is suppressed while (or 15 minutes after) `SpotInterruption{node=X}` fires.
- Node-level pages only for **on-demand/system** nodes, with `for: 15m`. Spot node alerts go to Slack, not the pager.
- **Page on symptoms instead:**
  - SLO burn-rate (error rate, p99 latency).
  - Available replicas below desired for 10 minutes.
  - Pods `Pending` > 10m (replacement capacity never arrived: ICE, broken Karpenter).
  - > 20% of nodes NotReady, or a spot node unreachable *without* an interruption notice: a real failure, page immediately.
- Add a Watchdog / dead-man's-switch alert so a silent alerting pipeline doesn't hide incidents.
- High reclaim *rate* goes to a daily ticket ("diversify instance types"), not a page.

## 3. Cloudflare site, mobile LCP 5 s

1. **Field vs lab:** PageSpeed/CrUX plus WebPageTest on a mobile profile. If HTML **TTFB** is 1.5–3 s, the HTML comes from origin. If TTFB is fast, the problem is render-side (hero image, fonts, JS).
2. **Headers:** `curl -sI -A 'iPhone' https://site/ | grep -iE 'cf-cache-status|cache-control|age|set-cookie|vary'`
   - `DYNAMIC`: HTML is not cached by default, so a Cache Rule is needed.
   - `BYPASS`: the origin sends `Cache-Control: private/no-store`, or a `Set-Cookie` on every page.
   - `MISS` every time, with `Age: 0`: a fragmented cache key (`Vary: User-Agent/Cookie`, `utm_*` query strings).
3. **Rules:**
   - Is a Cache Rule marking HTML as eligible, with an edge TTL?
   - Does a later rule or a legacy Page Rule override it?
   - Is there a bypass-on-cookie rule that matches everyone? Is Development Mode on?
4. **Origin:** `curl --resolve` straight to the origin to see its real headers and TTFB. Fix anonymous pages to send `Cache-Control: public, s-maxage=…` and no cookies.
5. **Fix and re-test:**
   - HTML cache rule with `stale-while-revalidate`, bypass only for logged-in cookies.
   - Strip marketing params from the cache key, enable Tiered Cache, purge on deploy.
   - Expect `HIT` and TTFB < 200 ms.
   - Then preload the LCP image (`fetchpriority=high`, AVIF) and defer third-party JS.
   - Confirm in CrUX over 28 days.

## 4. Application secrets on EKS

| | External Secrets Operator + AWS Secrets Manager | Sealed Secrets / SOPS in Git |
|---|---|---|
| Source of truth | AWS, outside the cluster | Ciphertext in Git |
| Rotation | In AWS (native RDS rotation), auto-refreshed into the cluster | Re-encrypt and commit, per cluster |
| Multi-cluster | All clusters read the same secret via Pod Identity/IRSA | Key pair per cluster, N copies |
| Access and audit | IAM per service account + CloudTrail on every read | Whoever holds the cluster key; no read audit |
| Cluster loss | Secrets come back automatically | Lose the key → re-seal everything |

**Pick: External Secrets Operator + AWS Secrets Manager.**
- For several prod clusters it gives one source of truth, per-app IAM scoping, audit, and managed rotation.
- Clusters stay disposable, and Git holds only `ExternalSecret` references.
- Guardrails:
  - Pod Identity role per app;
  - `/{env}/{app}/…` paths;
  - KMS key per environment;
  - KMS envelope encryption for etcd;
  - no human `get secret` in prod.
- SOPS + KMS only for the few bootstrap secrets needed before ESO runs.
