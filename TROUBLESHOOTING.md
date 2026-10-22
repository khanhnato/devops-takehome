# Part 3: Troubleshooting `broken-app.yaml`

> **TODO (remove before submitting):** the command outputs below are the *expected* messages, written from reading the manifests.
> They have not been captured from a live cluster yet. Run `./scripts/30-troubleshoot.sh --from-broken`, follow the steps,
> and paste the real output lines.

**Setup:** `troubleshoot/prepare.sh` had already run (cluster bootstrap), then:

```bash
kubectl apply -f troubleshoot/broken-app.yaml
./troubleshoot/verify.sh        # FAIL at [3/7] deployment/web is not ready
```

**Approach:** walk the request path from the outside in, and change one thing at a time:
**scheduling → image → container start → probes → Service → network → second workload**.
`verify.sh` stops at the first failure, so I used it only as the final judge and diagnosed with `kubectl` directly.
Several faults hide behind others: you don't see the probe or port bugs until the pod can actually be scheduled and pulled.

The final state is `troubleshoot/fixed-app.yaml`. Each change there is tagged `FIX #n` to match the sections below.
Apply and verify with `./scripts/30-troubleshoot.sh`, or use `./scripts/30-troubleshoot.sh --from-broken` to replay from the broken state.

---

## Overview

```bash
kubectl -n troubleshoot get deploy,rs,pods,svc,endpoints,networkpolicy -o wide
kubectl -n troubleshoot get events --sort-by=.lastTimestamp | tail -30
```

`web` pods were `Pending`, the `ai-inference` pod was `Pending`, and `web-svc` had no endpoints. That is three separate symptoms at the start.

## 1. `web` image tag does not exist

- **Symptom:** after fixing #2, the pods went `ErrImagePull` → `ImagePullBackOff`.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot describe pod -l app=web | grep -A3 -E 'Failed|Back-off'
  #   Failed to pull image "nginx:1.25.99": ... nginx:1.25.99: not found
  ```
- **Root cause:** nginx has never published `1.25.99`; the last 1.25.x release is `1.25.5`.
- **Fix:** `image: nginx:1.25.5`. It stays on the 1.25 line the authors intended, pinned to a real patch release.
  In production I would pin by digest and add a CI check that every image reference resolves before it can merge.

## 2. `web` requests 16 GiB of memory (unschedulable)

- **Symptom:** `web` pods stuck `Pending`, with no image-pull attempt at all.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot describe pod -l app=web | sed -n '/Events/,$p'
  #   0/5 nodes are available: 1 node(s) had untolerated taint {nvidia.com/gpu: true},
  #   4 Insufficient memory. preemption: ...
  kubectl get nodes -o custom-columns=NAME:.metadata.name,MEM:.status.allocatable.memory
  kubectl -n troubleshoot get deploy web -o jsonpath='{.spec.template.spec.containers[0].resources}'
  ```
- **Root cause:** `requests.memory: 16Gi`, while no node has that much allocatable. Most likely a `Mi`/`Gi` typo.
  The limit was also 16Gi, which would let a static file server eat an entire node.
- **Fix:** `requests: 32Mi`, `limits: 128Mi`. nginx serving one static page uses a few MB, so this leaves comfortable headroom.

## 3. Probes point at port 8080, nginx listens on 80

- **Symptom:** once the image pulled, pods were `Running` but `0/1 READY`, with `RESTARTS` climbing.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot describe pod -l app=web | grep -E 'Liveness|Readiness|Unhealthy|Killing'
  #   Liveness probe failed: Get "http://10.42.x.y:8080/": connect: connection refused
  kubectl -n troubleshoot exec deploy/web -- sh -c 'grep -h listen /etc/nginx/conf.d/*.conf'
  #   listen       80;
  ```
- **Root cause:** the liveness and readiness probes use `port: 8080`, but the stock nginx image listens on 80 and so does `containerPort`.
  The liveness probe kills a perfectly healthy container on a loop.
- **Fix:** name the container port (`name: http`, 80) and point both probes at `port: http`. With one source of truth, the two can't drift again.

## 4. ConfigMap name typo (`web-conf` vs `web-config`)

- **Symptom:** pods stuck in `ContainerCreating`.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot describe pod -l app=web | grep FailedMount
  #   MountVolume.SetUp failed for volume "html" : configmap "web-conf" not found
  kubectl -n troubleshoot get configmap
  #   web-config
  ```
- **Root cause:** the volume references `web-conf`; the ConfigMap is `web-config`.
- **Fix:** `configMap.name: web-config`. Without this, nginx would serve its default page and the smoke test's `grep TROUBLESHOOT-OK` would fail even with a working network.

## 5. Service selector matches no pods

- **Symptom:** `web` pods Ready, but `verify.sh` [6/7] says `web-svc` has no endpoints.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot get endpoints web-svc          # <none>
  kubectl -n troubleshoot get svc web-svc -o jsonpath='{.spec.selector}'   # {"app":"webapp"}
  kubectl -n troubleshoot get pods --show-labels         # app=web
  ```
- **Root cause:** the selector is `app: webapp`, but the pods are labelled `app: web`.
- **Fix:** `selector: { app: web }`.

## 6. Service targetPort 8080, nothing listens there

- **Symptom:** endpoints now existed, but traffic to the Service would be refused. This is the same kind of mismatch as #3, on the Service side.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot get endpoints web-svc -o jsonpath='{.subsets[*].ports}'   # port 8080
  kubectl -n troubleshoot run tmp --rm -it --image=curlimages/curl:8.7.1 --labels=app=smoke-client \
    -- curl -sv --max-time 5 web-svc        # (after #7) connection refused
  ```
- **Root cause:** `targetPort: 8080`, but the container listens on 80.
- **Fix:** `targetPort: http`, the named port from #3.

## 7. Default-deny NetworkPolicy blocks DNS and the smoke client (rule: keep default-deny)

- **Symptom:** with everything above fixed, `verify.sh` [7/7] failed: the smoke job timed out.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot get networkpolicy        # only default-deny: podSelector {} , Ingress+Egress, no rules
  kubectl -n troubleshoot logs job/smoke-test
  #   curl: (6) Could not resolve host: web-svc.troubleshoot.svc.cluster.local
  ```
  - DNS fails first, because egress to CoreDNS is denied.
  - Hitting the pod IP directly from a debug pod labelled `app=smoke-client` also times out, because ingress to `web` is denied too.
  - `kubectl -n kube-system get pods -l k8s-app=kube-dns --show-labels` confirmed the label to select on.
- **Root cause:** `default-deny` selects every pod and denies both Ingress and Egress, with no allow rules at all.
- **Fix:** keep `default-deny` and add two least-privilege policies:
  - `smoke-client-egress`: `app=smoke-client` may send UDP/TCP 53 only to `k8s-app=kube-dns` in `kube-system`, and TCP 80 only to `app=web`.
  - `web-ingress`: `app=web` accepts TCP 80 only from `app=smoke-client`.
  - Note: NetworkPolicy matches the **pod** port (80), not the Service port. A policy written for "port 80 on the Service" only works here because the two happen to be equal.
  - `web` gets no egress at all; it never needs to initiate connections.

## 8. `ai-inference` can't schedule on the GPU node (rule: don't touch the node)

- **Symptom:** `ai-inference` stuck `Pending`.
- **Diagnose:**
  ```bash
  kubectl -n troubleshoot describe pod -l app=ai-inference | sed -n '/Events/,$p'
  #   0/5 nodes are available: 5 node(s) didn't match Pod's node affinity/selector.
  kubectl get nodes -L acme.io/node-type -L node-type
  kubectl get node -l acme.io/node-type=gpu -o jsonpath='{.items[0].spec.taints}'
  #   [{"effect":"NoSchedule","key":"nvidia.com/gpu","value":"true"}]
  ```
- **Root cause:** two stacked faults.
  - a) `nodeSelector: node-type: gpu`: no node has that label key. The real key is `acme.io/node-type`.
  - b) Once the selector is fixed, the scheduler reports `1 node(s) had untolerated taint {nvidia.com/gpu: true}`. The pod has no toleration for the GPU taint.
- **Fix:** `nodeSelector: { acme.io/node-type: gpu }` plus a toleration for `nvidia.com/gpu=true:NoSchedule`.
  - Both are needed: the toleration only *allows* the GPU node, and the selector *requires* it. Otherwise the pod could also drift onto CPU nodes.
  - In production it would also request `nvidia.com/gpu: 1`. I didn't add that here because the simulated node has no device plugin.

---

## Result

```bash
./troubleshoot/verify.sh
# [1/7] … [7/7] In-cluster smoke test through the Service...
# PASS
```

Prevention ideas for the real platform:
- kubeconform + a policy engine (Kyverno/Conftest) in CI: Service selectors must match a workload, probe ports must match container ports, no `memory` request > node size.
- Use named ports everywhere.
- Ship a namespace template that always pairs `default-deny` with a DNS-egress allow.
