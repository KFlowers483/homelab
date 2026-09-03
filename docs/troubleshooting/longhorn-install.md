# Longhorn install night three cascading failures

**Date:** 2026-09-02 / 03
**Status:** Resolved, cluster stable
**Fix commit:** `201c5cc` "Disable Longhorn pre-upgrade hook job for ArgoCD"

Three separate failures in one evening, each hiding the next:

1. ArgoCD deadlocked on Longhorn's Helm pre-upgrade hook
2. `longhorn-manager` crashlooped iSCSI prerequisites missing on all nodes
3. Control plane collapsed under the added load 2 vCPU / 4GB was not enough

---

## Failure 1 pre-upgrade hook deadlock

### Symptom

After merging the Longhorn Application to `main`, ArgoCD showed:

- `longhorn` — `OutOfSync` / `Missing`, `.status.conditions` **empty**
- `longhorn-system` namespace created, **zero resources in it**
- `kube-prometheus-stack` — sync status `Unknown`, `Degraded`, partially applied
- Two PVCs stuck `Pending` on `storageClassName: longhorn`

No error anywhere. Nothing in ArgoCD's UI or `conditions` said what was wrong.

### Root cause

```
kubectl -n argocd get applications.argoproj.io longhorn \
  -o jsonpath='{.status.operationState.message}'

waiting for completion of hook batch/Job/longhorn-pre-upgrade
```

The Longhorn chart ships `longhorn-pre-upgrade` as a Helm **`pre-upgrade`** hook.
Helm skips `pre-upgrade` hooks on a fresh install. ArgoCD does not make that
distinction it maps the hook to `PreSync` and runs it on *every* sync,
including the first. The job waits on a `longhorn-manager` that does not exist
yet, never completes, and the sync blocks at PreSync indefinitely.

Upstream documents this in a values comment:

> `preUpgradeChecker.jobEnabled`  "Disable this setting when installing
> Longhorn using Argo CD or other GitOps solutions."

### Fix

In `k3s/longhorn/values.yaml`:

```yaml
preUpgradeChecker:
  jobEnabled: false
  upgradeVersionCheck: true
```

Push, then clear the stuck operation the fix does nothing while the old
operation is still blocking:

```
kubectl -n argocd patch applications.argoproj.io longhorn --type merge -p '{"operation":null}'
kubectl -n argocd patch applications.argoproj.io longhorn --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl -n longhorn-system delete job longhorn-pre-upgrade --ignore-not-found --wait=false
```

Order matters: with `automated: true`, ArgoCD re-syncs within ~3 minutes. If the
fix is not on `main` first, it re-renders the same chart and recreates the hook.
Deleting the job twice and watching it come back is the tell.

---

## Failure 2 — iSCSI prerequisites missing

Once the hook cleared, `longhorn-manager` went `CrashLoopBackOff` on all three
nodes:

```
level=fatal msg="Error starting manager: failed to check environment, please
make sure you have iscsiadm/open-iscsi installed on the host ...
nsenter: failed to execute iscsiadm: No such file or directory: exit status 127"
```

`longhorn-manager` is a DaemonSet and runs on **every** node including the
control plane, so the iSCSI prerequisites are needed on all three even the
node that will host no replicas:

```
dnf install -y iscsi-initiator-utils nfs-utils cryptsetup
systemctl enable --now iscsid
printf 'iscsi_tcp\ndm_crypt\n' > /etc/modules-load.d/longhorn.conf
modprobe iscsi_tcp dm_crypt
```

One node stayed in CrashLoopBackOff after the packages were installed because
the backoff had grown to ~5 minutes with stale state. `kubectl delete pod`
forced a clean attempt and it came up `2/2` in 24 seconds.

CSI sidecars (`csi-attacher`, `csi-provisioner`, `csi-resizer`,
`csi-snapshotter`) restart repeatedly while the managers flap they lose the
CSI socket and reconnect. Not a separate fault; settles once managers are stable.

---

## Failure 3  control plane under-provisioned

About an hour after Longhorn came up, most services went down at once. Uptime
Kuma showed ArgoCD, Rancher, Vaultwarden, whoami and Traefik all failing
(`ECONNREFUSED` on the Traefik LB address) while all three k3s nodes and pfSense
still reported 100%.

### Symptom

```
Unable to connect to the server: net/http: TLS handshake timeout
```

Events showed `NodeNotReady` flapping on `k3s-worker2`, and
`AttachVolume.Attach failed ... node k3s-worker1 not found`.

### Root cause

VM 301 (`k3s-control`) on pve1, at 2 vCPU / 4GB:

- **CPU 108.97% of 2 CPUs** fully saturated, 70–90% sustained
- **Memory 86.21% (3.45 of 4.00 GiB)**
- Still pegged one minute after a reboot

CPU was the damaging one. etcd is very sensitive to scheduling latency; a
saturated CPU means missed heartbeat deadlines, which is exactly the
`NodeNotReady` flapping and API timeouts. Everything downstream Traefik,
Rancher, ArgoCD, the CSI sidecars was collateral.

The load came from adding `longhorn-manager` (1.2–1.5GB per node),
`node-exporter` and `kube-state-metrics` on top of etcd and the API server.
The `createDefaultDiskLabeledNodes: true` gate kept *disks* off the control
plane, but a DaemonSet lands there regardless of node labels.

### Fix

On pve1:

```
qm shutdown 301
qm set 301 --memory 8192 --cores 4
qm start 301
```

CPU dropped from 109% of 2 to **26% of 4**. Inside the guest, `free -h` showed
3.0Gi available of 7.5Gi with swap essentially untouched (12Mi of 3.2Gi). All
three nodes returned to `Ready` and every pod recovered on its own except
Grafana, which correctly waits on a PVC that cannot bind until Longhorn has a
disk.

### Note on the Proxmox memory gauge

The VM summary showed 90.67% memory after the bump, which looked alarming and
was not. With **no guest agent configured**, Proxmox reports the host-side KVM
process footprint, which includes guest page cache and grows to fill the
allocation. The number that matters is `available` from `free -h` inside the
guest.

---

## Diagnostic lessons

- **Empty `.status.conditions` means waiting, not failing.** A broken manifest
  or a resource limit produces a loud `ComparisonError`. Silence pointed at a
  blocked hook, and `.status.operationState.message` was the field that said so.
  Two wrong hypotheses repo-server OOM and gRPC max message size were burned
  before checking it. repo-server was healthy the whole time, rendering
  kube-prometheus-stack in under 320ms.
- **`kubectl get app` is ambiguous on this cluster.** Rancher registers
  `apps.catalog.cattle.io`, which wins the `app`/`apps` short name over ArgoCD's
  `applications.argoproj.io`. `kubectl -n argocd get app` returned
  "No resources found" and `kubectl patch app longhorn` returned
  `apps.catalog.cattle.io "longhorn" not found` both misleading. Always use
  `applications.argoproj.io` here.
- **Nodes reporting healthy while every service is down means look up, not
  down.** The node and API monitors staying green while Traefik refused
  connections pointed at the control plane's ability to *serve*, not at the
  workloads.
- **Pre-existing noise is not evidence.** `capi-controller-manager` (182
  restarts, 21d), `fleet-agent` (21d) and `metrics-server` (95 restarts, 119d)
  were all failing long before this evening and were briefly mistaken for
  fallout.

## Baseline after this night

- VM 301 `k3s-control` — pve1, **4 vCPU / 8GB**, 32GB boot disk
- VM 302 `k3s-worker1` — pve2
- VM 303 `k3s-worker2` — pve3
- pve1 `e1000e` hang count: **0** through the heaviest load since the NIC fix
- Longhorn installed and running, **zero disks, zero labels, holding no data**
- `local-path` still the default StorageClass; `longhorn` is opt-in per PVC

## Still to do

Worker disks (`qm set 302/303 -scsi1 <pool>:100`), mkfs + fstab by UUID,
preflight, then the two `create-default-disk` labels. Deliberately not done on
this night adding storage load to a cluster that had just been dropping node
heartbeats was the wrong move.
