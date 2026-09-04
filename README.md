# Homelab

Building out a full home lab from scratch: a 3-node Proxmox cluster
running on Lenovo ThinkCentre M720q Tinys with a k3s Kubernetes cluster
on top. I already work with infrastructure day to day, this lab is how
I go deeper, break things on my own time, and keep building on what I know.

Currently active duty Air Force working in IT infrastructure.

## What's Running

| Layer | Tech |
|-------|------|
| Hypervisor | Proxmox VE 9.1.1 (3-node cluster) |
| Networking | pfSense + VLANs on Netgear GS308E |
| Kubernetes | k3s v1.35.4 (1 control plane, 2 workers) |
| OS | Rocky Linux 9.7 |
| Load balancer | MetalLB v0.15.2 (L2 mode, VLAN 30 pool) |
| Ingress | Traefik (Helm, ArgoCD-managed) |
| GitOps | ArgoCD, app-of-apps, everything defined in `apps/` |
| Certificates | cert-manager + internal homelab CA |
| Cluster mgmt | Rancher (`rancher.home`) |
| Storage | Longhorn 1.12.1, 2 replicas across the workers |
| Monitoring | Prometheus + Grafana + Alertmanager, Uptime Kuma (`uptime.home`) |
| Secrets | Vaultwarden (`vault.home`) |

## Hardware

- 3x Lenovo ThinkCentre M720q Tiny, 16GB RAM, 512GB NVMe each
- Node 1 has an extra 1TB SSD for VM storage
- Netgate SG-3100 running pfSense
- Netgear GS308E managed switch

## VM Layout

| VM | Name | Host | Resources | Storage |
|----|------|------|-----------|---------|
| 301 | k3s-control | pve1 | 4 vCPU / 8GB | 32GB boot only |
| 302 | k3s-worker1 | pve2 | 4 vCPU / 8GB | 32GB boot + 100GB Longhorn |
| 303 | k3s-worker2 | pve3 | 4 vCPU / 8GB | 32GB boot + 100GB Longhorn |

The control plane deliberately has no Longhorn disk. It runs etcd and the
API server and nothing else should compete with those.

## Network

5 VLANs: management, Proxmox, k3s/services, LAN, and storage (planned).
Inter-VLAN routing handled by pfSense with explicit firewall rules
between segments. Full topology and VLAN/IP plan in
[docs/architecture.md](docs/architecture.md).

## Repo layout

- `apps/` - ArgoCD Application definitions (what ArgoCD watches)
- `k3s/` - the manifests and Helm values those Applications point at
- `migrations/` - one-shot jobs, kept outside the app-of-apps path on purpose
- `scripts/` - node-side helpers, not deployed by ArgoCD
- `docs/` - architecture, setup notes and troubleshooting, written as I go

## Progress

- [x] Network design and VLAN configuration
- [x] Proxmox 3-node cluster
- [x] k3s VM provisioning
- [x] k3s cluster install and configuration
- [x] Load balancing + ingress (MetalLB, Traefik)
- [x] GitOps via ArgoCD (apps managed from this repo)
- [x] App-of-apps root Application, new services deploy on push
- [x] cert-manager + internal CA
- [x] Rancher for cluster management
- [x] Wildcard DNS for *.home
- [x] Architecture diagrams
- [x] Health probes + resource requests/limits
- [x] NetworkPolicy (default-deny ingress)
- [x] Longhorn replicated storage, 2 replicas across both workers
- [x] Uptime Kuma migrated from local-path to a Longhorn PVC
- [x] Prometheus + Grafana + Alertmanager on replicated storage
- [x] Node failure test: rebooted a worker, volumes degraded and rebuilt on their own
- [ ] Backup target on VLAN 40 + a tested restore
- [ ] Internal TLS on every service (new services have it, older ones don't yet)

## Docs

- [Architecture](docs/architecture.md)
- [Proxmox Cluster Setup](docs/proxmox-cluster.md)
- [k3s setup](docs/k3s-setup.md)
- [Rancher](docs/rancher.md)
- [k9s](docs/k9s.md)

## Troubleshooting writeups

Things that broke, and what actually fixed them:

- [pve1 NIC drops off the network](docs/troubleshooting/node1-network-dropout.md).
  Intel I219-V `e1000e` TX ring hang. Six-day silent outage. Fixed by
  disabling segmentation offloads, then proven under real storage load.
- [Longhorn install](docs/troubleshooting/longhorn-install.md). Seven
  separate failures across two evenings, each one hiding the next: an
  ArgoCD hook deadlock, missing iSCSI packages, a control plane that ran out
  of CPU, an OOMKilled Grafana, a zone anti-affinity setting with no zones,
  a host firewall hiding two of three nodes from Prometheus, and ArgoCD
  quietly undoing a manual scale-down mid-migration.
