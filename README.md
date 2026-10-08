# homelab-gitops

GitOps repository for a home Kubernetes lab: 3× Raspberry Pi 4 (8 GB, ARM64) running k3s with Cilium.
[Argo CD](https://argo-cd.readthedocs.io/) manages the cluster with the app-of-apps pattern — and manages itself:
upgrading Argo CD is a pull request.

## How it works

```
bootstrap/root.yaml          # root Application — the only manifest ever applied by hand
apps/                        # one Application per component; root syncs everything here
  argocd.yaml                #   → platform/argocd (Argo CD manages itself)
  kube-prometheus-stack.yaml #   → platform/kube-prometheus-stack (monitoring)
platform/<component>/        # the component itself
  Chart.yaml / Chart.lock    #   umbrella Helm chart: upstream chart as a dependency, version pinned here
  values.yaml                #   all settings, under the dependency's key
```

**One source per component.** A component's version and settings live only in `platform/<component>/`.
Its `Application` in `apps/` points at that path in this repository, so Argo CD and a manual
`helm template` render exactly the same thing. No multi-source Applications.

Argo CD runs on the control-plane node (`node-role=control-plane`, with a toleration for its
`NoSchedule` taint), without Dex, notifications or an ingress. There is no Helm release in the
cluster: Argo CD is the only owner of its objects; `helm install/upgrade` are never used.

| Application | Path | Sync policy |
|---|---|---|
| `root` | `apps/` | automated, `selfHeal`, `prune` |
| `argocd` | `platform/argocd` | automated, `selfHeal`, no prune; no finalizer, `Prune=false` |
| `kube-prometheus-stack` | `platform/kube-prometheus-stack` | automated, `selfHeal`, `prune`; no finalizer (CRDs); `ServerSideApply` |
| `cert-manager` | `platform/cert-manager` | automated, `selfHeal`, `prune`; no finalizer (CRDs); `ServerSideApply` |
| `vault` | `platform/vault` | automated, `selfHeal`, `prune`; no finalizer (data) |
| `external-secrets` | `platform/external-secrets` | automated, `selfHeal`, `prune`; no finalizer (CRDs); `ServerSideApply` |

## Bootstrap from scratch (= disaster recovery)

Needs `kubectl` with cluster-admin and `helm` (used only as a renderer).

```sh
kubectl create namespace argocd
helm dependency build platform/argocd
helm template argocd platform/argocd -n argocd | kubectl apply --server-side --force-conflicts -f -
kubectl -n argocd rollout status deploy --timeout=5m
kubectl create namespace monitoring       # Grafana admin Secret must exist before its first sync
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin --from-literal=admin-password='<from the password manager>'
kubectl apply -f bootstrap/root.yaml      # the only manual apply, once
```

Within a few minutes `root` picks up `apps/argocd.yaml` and Argo CD adopts its own objects
(no pod restarts — the render is identical).

The same `helm template … | kubectl apply --server-side --force-conflicts` is the **emergency path**
when a bad values change has broken Argo CD: fix `values.yaml` locally, run it, push the fix.
On a healthy Argo CD it changes nothing. `--force-conflicts` is required: after adoption Argo CD
owns the fields, and the render from git must win.

## Health check

About 5 minutes after a push:

```sh
kubectl get pods -n argocd                      # all Running (redis-secret-init: Completed)
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision,RECONCILED:.status.reconciledAt'
```

`root` and `argocd` must be `Synced`/`Healthy` on the pushed revision **and** `RECONCILED` must be
fresh (minutes old). A dead application controller leaves the last status in place — an old
`reconciledAt` is the only sign. Otherwise: `kubectl describe application <name> -n argocd`.

After a power loss everything comes back on its own; running workloads are not touched while
Argo CD or GitHub is down.

## UI access

No ingress. Over the private network:

```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443   # https://localhost:8080, user admin
```

The initial `admin` password is read once from `argocd-initial-admin-secret`, stored in a password
manager, and the secret is deleted (as the Argo CD docs recommend).

## Adding a component

1. `platform/<name>/Chart.yaml` with the upstream chart as a pinned dependency, `values.yaml`,
   `helm dependency build`, commit `Chart.lock`. Check: `helm template <name> platform/<name>`.
2. `apps/<name>.yaml` — an `Application` pointing at `platform/<name>`.
3. Push. `root` creates the Application; it syncs.

**Finalizer rule.** `resources-finalizer.argocd.argoproj.io` (delete the file → delete the
resources) only on components **without CRDs and without data**. Components with CRDs or data
(e.g. Vault, External Secrets Operator) get no finalizer: deleting the file leaves the resources in
the cluster, data is removed by hand. `argocd` itself never has one.

## Secrets and certificates

**cert-manager** runs the lab's internal CA: a self-signed root (`homelab-ca`, 10 years) behind the
`ClusterIssuer` `homelab-ca`. No ACME — nothing is exposed to the internet. Consumers trust `ca.crt`
of Secret `homelab-ca` in `cert-manager` (public). Losing the CA key means a new CA and a new
`caBundle` for every consumer; no data is lost.

**Vault** — one node, integrated storage (Raft) on the app node, TLS only (certificate `vault-tls`
from `homelab-ca`, 1 year). No HA on purpose: the only consumer is External Secrets Operator, and the
Kubernetes Secrets it writes survive Vault being sealed or down. Unseal is manual (Shamir, 3 keys,
threshold 2, kept in a password manager) — a sealed Vault does not stop running workloads. Raft data
sits on the SD card (`local-path`) **without backup**: the reference copy of every value is the
password manager, so losing Vault means re-initialising it and re-entering the values.
- The root token is revoked after setup; `generate-root` from the unseal keys is enabled without a
  token (`enable_unauthenticated_access`, Vault 2.0 requires one by default — CVE-2026-5807).
- The StatefulSet uses `OnDelete`: a config change takes effect after deleting the pod, then unseal.
- cert-manager renews `vault-tls` 30 days ahead; Vault reads it on `kubectl exec -n vault vault-0 --
  kill -HUP 1` (no restart, no unseal) or on any restart of the pod. **No alert catches a forgotten
  SIGHUP:** `CertificateExpiresSoon` sees the renewed Secret, while Vault keeps serving the old
  certificate until it expires — then External Secrets can no longer sync (Application `Degraded`).
  Hence a calendar reminder for the renewal date (`kubectl get certificate vault-tls -n vault`,
  `RENEWAL TIME`).

**External Secrets Operator** — namespaced `SecretStore`s only (cluster-wide stores and push secrets
are disabled): every namespace logs in to Vault with its own Kubernetes-auth role and reads only its
own path. Secrets in the k3s datastore are encrypted at rest (`secrets-encryption` on the server).

## Monitoring

[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
in namespace `monitoring`: Prometheus Operator, one Prometheus, one Alertmanager, Grafana,
kube-state-metrics and node-exporter. Everything except node-exporter runs on the data node
(`node-role=data`); node-exporter is a DaemonSet on all three nodes.

**Nothing is written to SD cards.** No PVCs: Prometheus TSDB (`retention: 3d`, `retentionSize: 768MB`,
tmpfs `sizeLimit: 1Gi`), Alertmanager state and Grafana's sqlite live in memory-backed `emptyDir`.
tmpfs counts against the container memory limit, so Prometheus' limit = working memory + 1Gi.
Metrics history, silences and Grafana sessions are lost on a pod restart or power loss — accepted
until metrics are shipped to object storage. Hence: **no silences** — a noisy rule is disabled in
`values.yaml` with a comment instead.

**Resources** are set from measured peaks (a cold start of all nodes included): requests ≈ steady use,
memory limits ≈ 1.5–2× the peak; the measurements are next to each value in `values.yaml`.
Prometheus is the big one: ~0.5 GiB working memory plus the TSDB tmpfs (limit 2.5Gi), then Grafana
(~455Mi with its sqlite tmpfs). 80–100k series (relabel apiserver histograms if it grows past that). Signal to rebalance: `node_memory_MemAvailable`
below 1 GiB on the data node.

**Not collected on k3s.** controller-manager and scheduler run inside the k3s process bound to
`127.0.0.1`, there is no etcd (single server, sqlite/kine), kube-proxy is replaced by Cilium.
Those targets and their rule groups are disabled. Exposing them would need k3s flags, which belong
to the node setup, not to this repository. Cilium/Hubble metrics are not scraped either (Cilium is
not managed by Argo CD). node-exporter runs without `hostNetwork` (host firewalls stay closed for
port 9100), so its network counters are the pod's, not the node's; CPU, memory and filesystems are
the node's (`hostPID`, host `/`, `/proc`, `/sys` read-only).

**Admission webhooks are off.** Their certificates come from Helm hook jobs that do not work under
Argo CD. Owners of `PrometheusRule` objects validate them in CI (`promtool check rules`).

**Lab rules** (Argo CD, monitoring itself, later SD cards, certificates, secrets) live in one place:
`additionalPrometheusRulesMap.homelab` in `platform/kube-prometheus-stack/values.yaml`. Argo CD only
exposes plain metrics Services; their ServiceMonitor is `prometheus.additionalServiceMonitors` there,
so Argo CD never depends on the monitoring CRDs. `Watchdog` always fires — that is the heartbeat.

**Disabled default rules** (`defaultRules` in `values.yaml`, each with its reason there). On a healthy
cluster only `Watchdog` (and `InfoInhibitor`) fire; anything else is a real signal.

| Rule / group | Why |
|---|---|
| groups `etcd`, `kubeControllerManager`, `kubeProxy`, `kubeSchedulerAlerting`, `kubeSchedulerRecording` | their targets do not exist on k3s (see above) |
| `CPUThrottlingHigh` | small containers with CPU limits on a Pi are throttled in idle bursts; starvation still shows as `KubePodCrashLooping`/`KubePodNotReady` |

### Access

No ingress. Over the private network:

```sh
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80          # http://localhost:3000
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090     # http://localhost:9090
kubectl port-forward svc/kube-prometheus-stack-alertmanager -n monitoring 9093:9093   # http://localhost:9093
```

Grafana login comes from the `grafana-admin` Secret (keys `admin-user`, `admin-password`), created
by hand before the first sync (see Bootstrap) with a random password kept in a password manager.
The chart's default password is never used. No anonymous access.

### Contracts

- **Firing alerts** (for health checks): Alertmanager API through the port-forward above,
  `GET http://localhost:9093/api/v2/alerts`. **No `Watchdog` in the answer means monitoring is
  broken**, not "no alerts": if Prometheus is down, Alertmanager resolves everything within minutes.
- **Applications with ServiceMonitor/PodMonitor/PrometheusRule/Probe:** picked up in any namespace
  without any labels (their selectors and namespace selectors are `{}`). `ScrapeConfig` is the
  exception: it still needs the label `release: kube-prometheus-stack` (chart default).
- **History:** rule windows must not exceed the retention (3d), and after a Prometheus restart long
  windows are unreliable until they refill. 28–30 day SLO periods and error budgets need remote write.
- **NetworkPolicy of an application:** Prometheus lives in namespace `monitoring`; allow ingress from
  ```yaml
  - namespaceSelector:
      matchLabels: { kubernetes.io/metadata.name: monitoring }
    podSelector:
      matchLabels: { app.kubernetes.io/name: prometheus }
  ```
  A bare `podSelector` without `namespaceSelector` matches only the application's own namespace.

### Upgrades

Read the chart's [UPGRADE.md](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/UPGRADE.md)
before every version bump: a major version usually means new CRDs. They are applied with the chart
(`ServerSideApply` — the CRDs exceed the client-side apply annotation limit).

### Rollback and reinstall

```sh
git rm apps/kube-prometheus-stack.yaml && git commit && git push   # no finalizer: resources stay
helm dependency build platform/kube-prometheus-stack
helm template kube-prometheus-stack platform/kube-prometheus-stack -n monitoring | kubectl delete --ignore-not-found -f -
kubectl delete namespace monitoring                                 # also deletes grafana-admin
kubectl get crd -o name | grep monitoring.coreos.com | xargs kubectl delete
```

Deleting the CRDs also deletes every `PrometheusRule`/`ServiceMonitor` of other applications.
Reinstall: recreate `grafana-admin` with the password from the password manager (Bootstrap), restore
the file, push.

## Rollback (remove Argo CD)

Valid **only while `apps/` contains nothing but `argocd`**: deleting the CRDs deletes every
`Application`, and with other components present that would take them down too.

```sh
kubectl delete application root -n argocd                  # root has no finalizer: nothing cascades
kubectl patch application argocd -n argocd --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]' || true   # in case one was added
helm template argocd platform/argocd -n argocd | kubectl delete --ignore-not-found -f -   # includes CRDs
kubectl delete namespace argocd
kubectl get crd | grep argoproj.io                         # must be empty
```
