# Homelab

Building out a full home lab from scratch — 3-node Proxmox cluster
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
| GitOps | ArgoCD — app-of-apps, apps defined in `apps/` |
| Certificates | cert-manager + internal homelab CA |
| Cluster mgmt | Rancher (`rancher.home`) |
| Storage | Longhorn 1.12.1 (replicated block storage) |
| Monitoring | Uptime Kuma (`uptime.home`), Prometheus + Grafana + Alertmanager |
| Secrets | Vaultwarden (`vault.home`) |

## Hardware

- 3x Lenovo ThinkCentre M720q Tiny — 16GB RAM, 512GB NVMe each
- Node 1 has an extra 1TB SSD for VM storage
- Netgate SG-3100 running pfSense
- Netgear GS308E managed switch

## VM Layout

| VM | Name | Host | Resources |
|----|------|------|-----------|
| 301 | k3s-control | pve1 | 4 vCPU / 8GB / 32GB disk |
| 302 | k3s-worker1 | pve2 | + 100GB Longhorn disk |
| 303 | k3s-worker2 | pve3 | + 100GB Longhorn disk |

## Network

5 VLANs — management, Proxmox, k3s/services, LAN, and storage
(planned). Inter-VLAN routing handled by pfSense with explicit
firewall rules between segments. Full topology and VLAN/IP plan in
[docs/architecture.md](docs/architecture.md).

## Repo layout

- `apps/` — ArgoCD Application definitions (what ArgoCD watches)
- `k3s/` — the manifests and Helm values those Applications point at
- `migrations/` — one-shot jobs, deliberately outside the app-of-apps path
- `scripts/` — node-side helpers, not deployed by ArgoCD
- `docs/` — architecture, setup notes and troubleshooting, written as I go

## Progress

- [x] Network design and VLAN configuration
- [x] Proxmox 3-node cluster
- [x] k3s VM provisioning
- [x] k3s cluster install and configuration
- [x] Load balancing + ingress (MetalLB, Traefik)
- [x] GitOps via ArgoCD (apps managed from this repo)
- [x] App-of-apps root Application — new services deploy on push
- [x] cert-manager + internal CA
- [x] Rancher for cluster management
- [x] Wildcard DNS for *.home
- [x] Architecture diagrams
- [x] Health probes + resource requests/limits
- [x] NetworkPolicy (default-deny ingress)
- [x] Longhorn deployed via ArgoCD
- [ ] Longhorn storage disks + replica scheduling
- [ ] Migrate Uptime Kuma to a replicated PVC
- [ ] Observability stack fully online (Prometheus + Grafana + Alertmanager)
- [ ] Node failure / recovery testing
- [ ] Backup target + tested restore
- [ ] Internal TLS on all services

## Docs

- [Architecture](docs/architecture.md)
- [Proxmox Cluster Setup](docs/proxmox-cluster.md)
- [k3s setup](docs/k3s-setup.md)
- [Rancher](docs/rancher.md)
- [k9s](docs/k9s.md)

## Troubleshooting writeups

Things that broke, and what actually fixed them:

- [pve1 NIC drops off the network](docs/troubleshooting/node1-network-dropout.md) —
  Intel I219-V `e1000e` TX ring hang, six-day silent outage, fixed by disabling
  segmentation offloads
- [Longhorn install night](docs/troubleshooting/longhorn-install.md) — three
  cascading failures: an ArgoCD/Helm pre-upgrade hook deadlock, missing iSCSI
  prerequisites on every node, and a control plane that ran out of CPU under the
  added load
