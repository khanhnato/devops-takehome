# Part 3: Troubleshooting `broken-app.yaml`

All output below is **real**: it was captured on the k3d lab (k3s v1.35.9) by applying `broken-app.yaml` and then fixing **one fault at a time** with `kubectl patch`, re-checking after each step.

The final state is [`troubleshoot/fixed-app.yaml`](troubleshoot/fixed-app.yaml). Each change in it is tagged `FIX #n`, numbered in the order the faults surfaced.

To reproduce: `./scripts/30-troubleshoot.sh --from-broken`. It applies the broken manifests, shows `verify.sh` failing, applies the fix and prints `PASS`.

**Approach:**
- Walk the path outside-in: scheduling → volumes → image → probes → Service → network → the second workload.
- Change one thing at a time. Several faults are hidden behind others: you can't see the probe bug until the pod schedules, mounts and pulls.
- `verify.sh` stops at the first failure, so it was the final judge only; I diagnosed with `kubectl` directly.

## Starting point

```console
$ kubectl apply -f troubleshoot/broken-app.yaml
$ kubectl -n troubleshoot get deploy,pods,svc,endpoints,networkpolicy -o wide
deployment.apps/ai-inference   0/1     1            0           20s   inference    busybox:1.36    app=ai-inference
deployment.apps/web            0/2     2            0           20s   nginx        nginx:1.25.99   app=web
pod/ai-inference-6fdb9f84d7-c2cwj   0/1     Pending   0          20s   <none>   <none>
pod/web-7dfd85c595-h24qs            0/1     Pending   0          20s   <none>   <none>
pod/web-7dfd85c595-hbbwr            0/1     Pending   0          20s   <none>   <none>
service/web-svc   ClusterIP   10.43.46.157   <none>        80/TCP    20s   app=webapp
endpoints/web-svc   <none>      20s
networkpolicy.networking.k8s.io/default-deny   <none>         20s
```

Three symptoms are visible straight away:
- both `web` pods `Pending`;
- `ai-inference` `Pending`;
- the Service has no endpoints. Its selector is already suspicious: `app=webapp`, while the Deployment uses `app=web`.

---

## 1. `web` requests 16 GiB of memory, so it is unschedulable

- **Symptom:** `web` pods stay `Pending`. There is no pull attempt at all.
- **Diagnose:**
  ```console
  $ kubectl -n troubleshoot describe pod/web-7dfd85c595-hbbwr | sed -n '/Events/,$p'
    Warning  FailedScheduling  20s   default-scheduler  0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 Insufficient memory. ...
  $ kubectl get nodes -o custom-columns=NAME:.metadata.name,ALLOCATABLE_MEM:.status.allocatable.memory
  k3d-quote-agent-0    10182728Ki        # ~9.7 GiB on every node
  $ kubectl -n troubleshoot get deploy web -o jsonpath='{.spec.template.spec.containers[0].resources}'
  {"limits":{"cpu":"500m","memory":"16Gi"},"requests":{"cpu":"100m","memory":"16Gi"}}
  ```
- **Root cause:** `requests.memory: 16Gi` is more than any node can allocate, most likely a `Mi`/`Gi` typo. The 16Gi limit would also let a static file server eat a whole node.
  The "1 untolerated taint" in the message is just the GPU node, which is correct and expected.
- **Fix (FIX #1):** `requests: 32Mi`, `limits: 128Mi`. nginx serving one static page needs a few MB.

## 2. ConfigMap name typo (`web-conf` vs `web-config`)

- **Symptom:** the new pod is scheduled but stuck in `ContainerCreating`.
- **Diagnose:**
  ```console
  $ kubectl -n troubleshoot describe pod/web-c4b7df547-s4f5q | sed -n '/Events/,$p'
    Normal   Scheduled    24s               default-scheduler  Successfully assigned troubleshoot/web-c4b7df547-s4f5q to k3d-quote-agent-0
    Warning  FailedMount  9s (x6 over 24s)  kubelet            MountVolume.SetUp failed for volume "html" : configmap "web-conf" not found
  $ kubectl -n troubleshoot get configmap
  web-config         1      45s
  ```
- **Root cause:** the volume references `web-conf`, but the ConfigMap is named `web-config`.
  Note the order: kubelet sets up volumes **before** pulling images, so this fault hid the bad image tag (#3).
- **Fix (FIX #2):** `configMap.name: web-config`. This also matters for the end-to-end check: without it, nginx would serve its default page and the smoke test's `grep TROUBLESHOOT-OK` would fail.

## 3. `web` image tag does not exist

- **Symptom:** once the volume mounts, the pod goes `ErrImagePull` → `ImagePullBackOff`.
- **Diagnose:**
  ```console
  $ kubectl -n troubleshoot describe pod/web-64f879c9cf-s8v5d | sed -n '/Events/,$p'
    Warning  Failed     2s    kubelet  Failed to pull image "nginx:1.25.99": ... docker.io/library/nginx:1.25.99: not found
    Normal   BackOff    1s    kubelet  Back-off pulling image "nginx:1.25.99"
  ```
- **Root cause:** `nginx:1.25.99` was never published. The last 1.25.x is `1.25.5`.
- **Fix (FIX #3):** `image: nginx:1.25.5`. It stays on the intended 1.25 line, pinned to a real patch release.
  In production I would pin by digest and have CI check that every image reference resolves before merge.

## 4. Probes target port 8080, but nginx listens on 80

- **Symptom:** the pod is `Running` but `0/1` ready, and `RESTARTS` keeps climbing.
- **Diagnose:**
  ```console
  $ kubectl -n troubleshoot get pods -l app=web
  web-b7d8555bd-fnsxm    0/1     Running             1 (6s ago)   46s
  $ kubectl -n troubleshoot describe pod/web-b7d8555bd-fnsxm | grep -E 'Liveness|Readiness|Unhealthy|Killing'
      Liveness:     http-get http://:8080/ delay=5s timeout=1s period=5s #success=1 #failure=3
    Warning  Unhealthy  6s (x4 over 18s)  kubelet  Readiness probe failed: Get "http://10.42.3.4:8080/": dial tcp 10.42.3.4:8080: connect: connection refused
    Normal   Killing    6s                kubelet  Container nginx failed liveness probe, will be restarted
  $ kubectl -n troubleshoot exec pod/web-b7d8555bd-fnsxm -- sh -c 'grep -h listen /etc/nginx/conf.d/*.conf'
      listen       80;
      listen  [::]:80;
  ```
- **Root cause:** both probes point at 8080, but the stock nginx image (and `containerPort`) is on 80. The liveness probe kills a healthy container in a loop.
- **Fix (FIX #4):** name the container port (`name: http`, 80) and point both probes at `port: http`. With one source of truth, the ports can't drift apart again. After this, `rollout status` succeeds.

## 5. Service selector matches no pods

- **Symptom:** the `web` pods are `1/1 Running`, but the Service still has no endpoints. This is `verify.sh` step [6/7].
- **Diagnose:**
  ```console
  $ kubectl -n troubleshoot get endpoints web-svc
  web-svc   <none>      2m50s
  $ kubectl -n troubleshoot get svc web-svc -o jsonpath='{.spec.selector}'
  {"app":"webapp"}
  $ kubectl -n troubleshoot get pods -l app=web --show-labels
  web-6b88f58556-hgwv6   1/1     Running   0   48s    app=web,pod-template-hash=6b88f58556
  ```
- **Root cause:** the selector is `app: webapp`, but the pods are labelled `app: web`.
- **Fix (FIX #5):** `selector: { app: web }`.

## 6. Service `targetPort: 8080`, where nothing listens

- **Symptom:** the endpoints now exist, but on the wrong port, so traffic would be refused.
- **Diagnose:**
  ```console
  $ kubectl -n troubleshoot get endpoints web-svc
  web-svc   10.42.1.5:8080,10.42.2.3:8080   2m53s
  $ kubectl -n troubleshoot get svc web-svc -o jsonpath='{.spec.ports}'
  [{"port":80,"protocol":"TCP","targetPort":8080}]
  ```
- **Root cause:** the same 80-vs-8080 mismatch as #4, this time on the Service side.
- **Fix (FIX #6):** `targetPort: http`, the named port from #4.

## 7. Default-deny NetworkPolicy blocks DNS and the client → web path (rule: keep default-deny)

- **Symptom:** with #1–#6 fixed, the smoke Job (`app=smoke-client`) fails.
- **Diagnose:**
  ```console
  $ kubectl -n troubleshoot get networkpolicy
  default-deny   <none>         3m15s          # selects every pod, Ingress+Egress, zero allow rules
  $ kubectl -n troubleshoot logs job/smoke-test
  curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 4 ms: Couldn't connect to server
  ```
  A connection refused in 4 ms is a policy REJECT, not a timeout: **ingress to `web` is denied**.
  To check **egress / DNS** too, I started a long-lived debug pod that only `default-deny` selects:
  ```console
  $ kubectl -n troubleshoot run curl-probe --image=curlimages/curl:8.7.1 --labels=app=dns-probe --command -- sleep 300
  $ kubectl -n troubleshoot exec curl-probe -- curl -sv --max-time 5 http://web-svc.troubleshoot.svc.cluster.local
  * Could not resolve host: web-svc.troubleshoot.svc.cluster.local
  $ kubectl -n kube-system get pods -l k8s-app=kube-dns --show-labels
  coredns-b644fd95b-7vfnt   1/1     Running   0   4m14s   k8s-app=kube-dns,pod-template-hash=b644fd95b
  ```
- **Root cause:** `default-deny` denies both directions, with no allow rules at all. DNS egress to CoreDNS is blocked, and so is ingress to `web`.
- **Why the smoke Job showed exit 7 instead of a DNS error:** k3s enforces NetworkPolicy with kube-router, which isolates a *new* pod a moment after it starts.
  The Job's first DNS lookup slipped through before its egress isolation was in place, while the long-running `web` pods were already isolated.
  A pod that has been running for a while gets exit 6 (`Could not resolve host`). Either way, both directions need explicit allows.
- **Fix (FIX #7):** keep `default-deny` and add two least-privilege policies:
  - `smoke-client-egress`: `app=smoke-client` may send UDP/TCP 53 **only** to `k8s-app=kube-dns` in `kube-system`, and TCP 80 **only** to `app=web`.
  - `web-ingress`: `app=web` accepts TCP 80 **only** from `app=smoke-client`.
  - NetworkPolicy matches the **pod** port (80), not the Service port. Here they happen to be equal.
  - `web` gets no egress rule; it never initiates connections.
  - Kubelet probes still pass under default-deny on k3s (verified: `web` stays `1/1 Ready`), because kube-router allows node-to-local-pod traffic.
    Seen in the node's iptables (`iptables-save` in the agent container): `"rule to permit the traffic to pods when source is the pod's local node" -m addrtype --src-type LOCAL -j ACCEPT`.
    Other CNIs (Calico, Cilium) behave similarly but not identically; worth checking per platform.

## 8. `ai-inference` cannot schedule onto the GPU node (rule: don't touch the node)

- **Symptom:** `ai-inference` stays `Pending`.
- **Diagnose:**
  ```console
  $ kubectl -n troubleshoot describe pod/ai-inference-6fdb9f84d7-c2cwj | sed -n '/Events/,$p'
    Warning  FailedScheduling  3m15s  default-scheduler  0/5 nodes are available: 1 node(s) had untolerated taint(s), 4 node(s) didn't match Pod's node affinity/selector. ...
  $ kubectl get nodes -L acme.io/node-type -L node-type
  NAME                 ...   NODE-TYPE   NODE-TYPE
  k3d-quote-agent-3    ...   gpu                       # label key is acme.io/node-type; nobody has `node-type`
  $ kubectl get node -l acme.io/node-type=gpu -o jsonpath='{.items[0].spec.taints}'
  [{"effect":"NoSchedule","key":"nvidia.com/gpu","value":"true"}]
  ```
- **Root cause:** two stacked faults, and the single scheduler message names both:
  - a) `nodeSelector: node-type: gpu`: no node carries that label key; the real key is `acme.io/node-type`.
  - b) There is no toleration for the GPU node's `nvidia.com/gpu=true:NoSchedule` taint ("1 node(s) had untolerated taint").

  Fixing only (a) leaves the pod `Pending` with exactly the same message: verified, the event repeated after patching the selector.
- **Fix (FIX #8a + #8b):** `nodeSelector: { acme.io/node-type: gpu }` **plus** a toleration for `nvidia.com/gpu=true:NoSchedule`.
  - The toleration only *allows* the GPU node; the selector *requires* it. Both are needed, or the pod could drift onto CPU nodes.
  - In production the pod would also request `nvidia.com/gpu: 1`. I didn't add that here because the simulated node has no device plugin, so the pod would never schedule.

---

## Result

```console
$ kubectl apply -f troubleshoot/fixed-app.yaml
$ kubectl -n troubleshoot get pods -o wide
ai-inference-f765cc8d8-nt8tn   1/1     Running   0   14s   10.42.4.2   k3d-quote-agent-3     # the GPU node
web-867444fdf8-64v4v           1/1     Running   0   7s    10.42.2.6   k3d-quote-agent-0
web-867444fdf8-7nfpx           1/1     Running   0   15s   10.42.3.5   k3d-quote-agent-1
$ ./troubleshoot/verify.sh
[1/7] default-deny NetworkPolicy must still exist (deleting it is not a fix)...
[2/7] Node labels and taints must be untouched (fixing the nodes is not a fix)...
[3/7] Deployment 'web' must be fully rolled out...
[4/7] Deployment 'ai-inference' must be fully rolled out...
[5/7] ai-inference pod must be running ON the GPU node...
[6/7] Service must have ready endpoints...
[7/7] In-cluster smoke test through the Service...

PASS
```

**Prevention on a real platform:**
- Run kubeconform plus a policy engine (Kyverno/Conftest) in CI. Rules worth having:
  - Service selectors must match a workload in the same chart;
  - probe ports must match container ports;
  - no memory request may exceed the largest node;
  - every image reference must resolve.
- Use named ports everywhere.
- Use a namespace template that always pairs `default-deny` with a DNS-egress allow.
