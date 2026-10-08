# Cluster nodes

Additions to `slotwatch/docs/INFRA-SETUP.md`. Required on every new or reinstalled node
before it joins the cluster (`k3s server` / `k3s agent`). INFRA-SETUP itself is frozen and is not edited.

## sysctl

All node sysctl settings live in `/etc/sysctl.d/` and are applied at boot by `systemd-sysctl`.

| File | Settings | Why | Source |
|---|---|---|---|
| `k8s.conf` | `net.bridge.bridge-nf-call-iptables = 1`, `net.bridge.bridge-nf-call-ip6tables = 1`, `net.ipv4.ip_forward = 1` | Pod networking | INFRA-SETUP, step 4.5 |
| `90-no-coredump.conf` | `kernel.core_pattern = \|/bin/false` | No core dumps on the node (below) | this file |

### Core dumps are off

The Cilium agent runs `cilium-envoy --version` every 2 minutes. On these nodes Envoy aborts at startup,
and with the Debian default `kernel.core_pattern = core` every crash
leaves a ~15 MB `core.<pid>` in the agent's working directory `/run/cilium/state`. That is the host's
`/run` tmpfs: it fills up in a few hours, after which `exec` into pods (exec probes, `kubectl exec`) and
the node journal break.

`|/bin/false` pipes every core dump to a program that exits immediately, so nothing is written anywhere.
The setting is global for the node, containers included: nobody debugs core dumps on these nodes, logs
and metrics stay.

```sh
echo 'kernel.core_pattern = |/bin/false' | sudo tee /etc/sysctl.d/90-no-coredump.conf
sudo systemctl restart systemd-sysctl
cat /proc/sys/kernel/core_pattern               # |/bin/false
sudo systemd-sysctl --cat-config | grep -n core_pattern
# the last match must be 90-no-coredump.conf; a later file setting core_pattern wins over it
```

Installing `systemd-coredump` or a manual `sysctl -w kernel.core_pattern=…` brings the problem back.
Rollback: `sudo rm /etc/sysctl.d/90-no-coredump.conf && sudo sysctl -w kernel.core_pattern=core`.

### What a healthy Cilium looks like here

The Envoy crash itself is not fixed (Cilium is left untouched), so the agent reports it. This is expected
and not a reason to act:

- the agent log has, every 2 minutes,
  `Envoy: Version check failed … failed to execute 'cilium-envoy --version': signal: aborted (core dumped)`
  — the kernel sets the "core dumped" flag even when the dump is discarded;
- `cilium-dbg status` shows `Cilium: Ok` and `Modules Health: … Degraded(1) …`;
- `cilium-dbg status --all-health` shows the only degraded module:
  `agent.controlplane.envoy-proxy` → `timer-job-version-check [DEGRADED] timer job errored`.

Anything else degraded is a real problem. Check after any node reboot or Cilium upgrade:

```sh
cat /proc/sys/kernel/core_pattern                # |/bin/false
ls /run/cilium/state | grep -c '^core'           # 0
df -h /run                                       # a few percent
```
