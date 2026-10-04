# homelab-gitops

GitOps repository for a home Kubernetes lab: 3× Raspberry Pi 4 (8 GB, ARM64) running k3s with Cilium.
[Argo CD](https://argo-cd.readthedocs.io/) manages the cluster with the app-of-apps pattern — and manages itself:
upgrading Argo CD is a pull request.

## How it works

```
bootstrap/root.yaml          # root Application — the only manifest ever applied by hand
apps/                        # one Application per component; root syncs everything here
  argocd.yaml                #   → platform/argocd (Argo CD manages itself)
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

## Bootstrap from scratch (= disaster recovery)

Needs `kubectl` with cluster-admin and `helm` (used only as a renderer).

```sh
kubectl create namespace argocd
helm dependency build platform/argocd
helm template argocd platform/argocd -n argocd | kubectl apply --server-side --force-conflicts -f -
kubectl -n argocd rollout status deploy --timeout=5m
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
