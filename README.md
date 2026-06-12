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

## Hardware

- 3x Lenovo ThinkCentre M720q Tiny — 16GB RAM, 512GB NVMe each
- Node 1 has an extra 1TB SSD for VM storage
- Netgate SG-3100 running pfSense
- Netgear GS308E managed switch

## Network

5 VLANs — management, Proxmox, k3s/services, LAN, and storage 
(planned). Inter-VLAN routing handled by pfSense with explicit 
firewall rules between segments.

## Progress

- [x] Network design and VLAN configuration
- [x] Proxmox 3-node cluster
- [x] k3s VM provisioning
- [x] k3s cluster install and configuration
- [ ] Services deployment (Traefik, ArgoCD, Longhorn, etc.)
- [ ] GitOps pipeline via GitHub Actions + ArgoCD
- [ ] Observability stack (Prometheus + Grafana)

## Docs

- [Proxmox Cluster Setup](docs/proxmox-cluster.md)
- [k3s setup](docs/k3s-setup.md)
