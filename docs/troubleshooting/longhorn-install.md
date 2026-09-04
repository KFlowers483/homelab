# Longhorn install: seven things that broke

Two evenings, Sep 2 through Sep 4. Longhorn 1.12.1 plus kube-prometheus-stack
88.6.2 deployed through ArgoCD. End state is good: every volume healthy with 2
replicas, monitoring on replicated storage, Uptime Kuma migrated off local-path,
and a worker reboot survived with no data loss.

Getting there took seven separate failures. Each one hid the next, which is
the main reason it took two nights instead of one. Writing them up in order.

1. ArgoCD deadlocked on Longhorn's Helm pre-upgrade hook
2. longhorn-manager crashlooped, iSCSI packages missing on every node
3. Control plane fell over, 2 vCPU / 4GB wasn't enough
4. Grafana OOMKilled on a memory limit I set too low
5. Replicas wouldn't schedule, zone anti-affinity with no zones defined
6. Prometheus only scraping one of three nodes, host firewall
7. ArgoCD undid my `kubectl scale` during the data migration

---

## 1. ArgoCD hook deadlock

Merged the Longhorn Application to main. ArgoCD showed:

- `longhorn` sitting at `OutOfSync` / `Missing`
- `longhorn-system` namespace created, zero resources inside it
- `.status.conditions` completely empty
- `kube-prometheus-stack` at sync status `Unknown`

No error anywhere. Nothing in the UI, nothing in conditions. I spent a while
chasing repo-server memory and gRPC message size limits, both wrong. The
actual answer was one field I hadn't checked:

```
kubectl -n argocd get applications.argoproj.io longhorn \
  -o jsonpath='{.status.operationState.message}'

waiting for completion of hook batch/Job/longhorn-pre-upgrade
```

The Longhorn chart ships a `longhorn-pre-upgrade` Job as a Helm `pre-upgrade`
hook. Helm skips those on a fresh install. ArgoCD doesn't, it maps the hook to
`PreSync` and runs it every sync. The job waits for a longhorn-manager that
doesn't exist yet and never finishes. Sync blocks forever at PreSync.

Longhorn's own values file has a comment about this that I hadn't read:
"Disable this setting when installing Longhorn using Argo CD or other GitOps
solutions."

Fix in `k3s/longhorn/values.yaml`:

```yaml
preUpgradeChecker:
  jobEnabled: false
  upgradeVersionCheck: true
```

Then clear the stuck operation, because the fix does nothing while the old one
is still blocking:

```
kubectl -n argocd patch applications.argoproj.io longhorn --type merge -p '{"operation":null}'
kubectl -n argocd patch applications.argoproj.io longhorn --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
kubectl -n longhorn-system delete job longhorn-pre-upgrade --ignore-not-found --wait=false
```

Push the values change first. Auto-sync fires about every 3 minutes, and if
the old chart is still on main it just recreates the hook. I deleted the job
twice and watched it come back before I figured that out.

Side note that cost me time: `kubectl get app` on this cluster resolves to
Rancher's `apps.catalog.cattle.io`, not ArgoCD's Application. So
`kubectl -n argocd get app` said "No resources found" while a dozen apps were
sitting right there. Always `applications.argoproj.io` here.

---

## 2. iSCSI packages missing

Once the hook cleared, longhorn-manager went CrashLoopBackOff on all three
nodes:

```
level=fatal msg="Error starting manager: failed to check environment, please
make sure you have iscsiadm/open-iscsi installed on the host ...
nsenter: failed to execute iscsiadm: No such file or directory"
```

longhorn-manager is a DaemonSet. It runs on every node including the control
plane, so the packages are needed everywhere even though only the workers get
disks:

```
dnf install -y iscsi-initiator-utils nfs-utils cryptsetup
systemctl enable --now iscsid
printf 'iscsi_tcp\ndm_crypt\n' > /etc/modules-load.d/longhorn.conf
modprobe iscsi_tcp dm_crypt
```

One manager stayed in CrashLoopBackOff after the install. The backoff had grown
to five minutes and it was sitting on stale state. `kubectl delete pod` forced
a clean start and it came up 2/2 in about 20 seconds.

The CSI sidecars (attacher, provisioner, resizer, snapshotter) restarted a lot
while the managers were flapping. That's them losing the CSI socket and
reconnecting, not a separate problem. Settled on its own.

---

## 3. Control plane out of CPU

About an hour after Longhorn came up, everything went down at once. Uptime Kuma
showed ArgoCD, Rancher, Vaultwarden, whoami and Traefik all failing while the
three k3s node monitors and pfSense stayed at 100%. kubectl itself was timing
out:

```
Unable to connect to the server: net/http: TLS handshake timeout
```

Events had `NodeNotReady` flapping on worker2 and attach failures saying
`node k3s-worker1 not found`.

The Proxmox summary for VM 301 (k3s-control) told the story. 2 vCPU / 4GB,
CPU at 109% of 2 cores, memory at 86%, and still pinned one minute after a
reboot. etcd is very sensitive to scheduling latency. When the CPU is
saturated it misses heartbeat deadlines and nodes start flapping. Everything
else was collateral.

The load came from longhorn-manager (1.2 to 1.5GB per node), node-exporter and
kube-state-metrics landing on top of etcd and the API server. I'd kept
Longhorn disks off the control plane with the label gate but a DaemonSet
lands there regardless.

Fix on pve1:

```
qm shutdown 301
qm set 301 --memory 8192 --cores 4
qm start 301
```

CPU dropped to 26% of 4 cores. I did the workers the same way (they were
2 vCPU / 6GB) before giving them storage.

One thing that confused me afterwards: the Proxmox memory gauge read 90% at 8GB.
That's the host-side KVM process footprint, which includes guest page cache and
grows to fill whatever you give it. Without a guest agent installed it's not a
useful number. `free -h` inside the VM showed 3GB available. Installing
qemu-guest-agent is on the list.

---

## 4. Grafana OOMKilled

Grafana kept flapping and Traefik returned 503 because there was no healthy
backend behind it.

```
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
Limits:
  memory: 512Mi
```

I'd set that limit in the values file thinking 512Mi was plenty. Grafana 13
runs a Go server, a SQLite database and dashboard rendering in one container
and it wants more than that. Raised to 1Gi with a 512Mi request.

Exit code 137 is the OOMKill fingerprint. Worth remembering because a limit
that's too tight looks exactly like an application crash until you read
`Last State`.

---

## 5. Replicas wouldn't schedule

After the disks were in and the workers were labeled, every volume sat at
`degraded`: one replica running, one `stopped` with no node and no disk
assigned.

```
Scheduled=False ReplicaSchedulingFailure replica scheduling failed
```

Both disks were fine. Ready, Schedulable, 107GB max with only 23GB and 7GB
scheduled. So not capacity and not the disks.

The cause was `replicaZoneSoftAntiAffinity: false` in my values. Longhorn reads
zones from the `topology.kubernetes.io/zone` node label. My nodes don't have
one, so they're all in the same empty zone. With hard zone anti-affinity, once
the first replica lands there is no second zone to put the other one in. One
replica per volume, forever, reported as a generic scheduling failure.

```yaml
replicaZoneSoftAntiAffinity: true    # was false
```

The node-level setting, `replicaSoftAntiAffinity: false`, stays. That's the
one that actually guarantees replicas on different nodes. Zone anti-affinity
only means something if you have racks or availability zones. I'd set it
because it sounded safer. It wasn't.

Volumes went healthy within a minute of the change syncing.

---

## 6. Firewall hiding two nodes from Prometheus

The Grafana dashboard showed one node on every panel. Three node-exporters
were running, the Service had all three endpoints, all three pods were
healthy. Everything kubectl could show me looked fine.

The Prometheus targets page didn't:

```
serviceMonitor/monitoring/kube-prometheus-stack-prometheus-node-exporter/0
1 / 3 up
  http://192.168.30.21:9100/metrics  down   dial tcp: connect: no route to host
  http://192.168.30.22:9100/metrics  down   dial tcp: connect: no route to host
  http://192.168.30.23:9100/metrics  up
```

firewalld. The k3s install opened 6443, 10250, 8472 (flannel) and 7946
(MetalLB), never 9100. The one working target was the node Prometheus happened
to be running on.

The part that took a minute to work out: the pod CIDR 10.42.0.0/16 was already
in firewalld's trusted zone and it made no difference. Flannel masquerades pod
traffic that leaves the pod network, and another node's host IP counts as
leaving. So the packet shows up at .21 with a source of 192.168.30.23 and the
pod-CIDR rule never matches.

`no route to host` instead of a timeout is the REJECT signature. A DROP would
just hang.

On all three nodes:

```
firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=192.168.30.0/24 port port=9100 protocol=tcp accept'
firewall-cmd --reload
```

This one bothers me more than the others because the monitoring looked like it
was working. One node reporting reads as "fine" if you're not counting lines.
Same shape as the six-day pve1 outage nobody noticed.

---

## 7. ArgoCD undoing my scale-down

Migrating Uptime Kuma from local-path to the Longhorn PVC. It's SQLite, so the
app has to be fully stopped before copying the database file or you get a
torn copy.

I scaled it down by hand:

```
kubectl -n uptime-kuma scale deploy/uptime-kuma --replicas=0
```

Pod terminated, I went to worker2 to take a tar backup of the data directory,
and got this:

```
tar: ./kuma.db: file changed as we read it
tar: ./kuma.db-wal: File removed before we read it
```

Listed the directory again and the WAL and SHM files were back with fresh
timestamps. Something was writing to the database while the deployment was
supposedly at zero replicas.

It was ArgoCD. The uptime-kuma Application has `selfHeal: true`. A manual
`kubectl scale` is drift from Git, which says `replicas: 1`, and ArgoCD
reverted it within about three minutes and started the app back up. Quietly.
No error, no event I was looking at. I took two backups of a live database
before I worked out what was happening.

The fix is to stop it in Git instead:

1. Commit `replicas: 0`, push, wait for the pod to actually go away
2. Confirm the WAL files are gone and `kuma.db` has stopped changing. Two
   clean `ls -la` reads 30 seconds apart, not one
3. Take the tar backup
4. Run the migration Job
5. Commit `claimName: uptime-kuma-data-longhorn` and `replicas: 1` together, push

The migration Job has a guard for exactly this. It refuses to copy if
`.db-wal` or `.db-shm` files exist in the source, and it errored correctly on
the first attempt. Once the app was properly stopped through Git it copied
2 files, 47,790,014 bytes, verified byte-for-byte on both sides.

Lesson: in a selfHeal repo, `kubectl scale` is not a way to stop anything.
The replica count has to change in Git or you're fighting the controller.

---

## Things I'd tell myself before starting

Three of the seven were caused by values I set stricter than the chart
default while trying to be careful: the Grafana memory limit, hard zone
anti-affinity, and leaving the pre-upgrade check enabled. Each one is good
advice somewhere. None of them was right for a three-node lab. Check what a
setting depends on before tightening it.

Empty `.status.conditions` in ArgoCD means waiting, not failing. A broken
manifest is loud. Silence means look at `operationState.message`.

A pod keeps its original spec forever. After I raised Grafana's limit,
`describe pod` still said 512Mi because the Deployment hadn't rolled a new one
yet. Check the Deployment.

Mount Longhorn disks by UUID in fstab. After a reboot, worker1's disk came
back as `/dev/sda` and worker2's stayed `/dev/sdb`. Same hardware, same config.
A device-name entry would have mounted nothing or the wrong thing.

If the nodes look healthy and every service is down, the problem is the
control plane's ability to serve, not the workloads.

---

## Where it ended up

- All four Longhorn volumes `healthy`, 2 replicas each across worker1 and worker2
- Prometheus, Grafana, Alertmanager on replicated storage
- Uptime Kuma on replicated storage, full history intact
- node-exporter scraping 3/3
- Rebooted worker1 with everything running. Volumes went degraded, rebuilt on
  their own, back to healthy. Nothing went down.
- pve1 hang count stayed at 0 through all of it, including the rebuild
  traffic. That NIC fix is proven now.

Still to do: backup target on VLAN 40 and an actual restore test. Replication
is not backup.
