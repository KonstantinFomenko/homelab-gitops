# homelab-gitops

GitOps repository for a home Kubernetes lab: 3× Raspberry Pi 4 (8 GB, ARM64) running k3s with Cilium.
Argo CD manages the cluster with the app-of-apps pattern and manages itself.

> Work in progress — full docs (bootstrap, health check, adding a component, rollback) follow.

## Layout

```
bootstrap/root.yaml   # root Application, applied by hand once
apps/                 # one Application per component
platform/<component>/ # the component itself: umbrella Helm chart with pinned version + values
```
