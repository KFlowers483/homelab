# k3s Cluster Setup

k3s running on Rocky Linux 9.7 VMs hosted on the Proxmox cluster. 
Control plane on pve1, workers on pve2 and pve3.

## VMs

| VM | Role | Node | IP |
|----|------|------|----|
| k3s-control | Control Plane | pve1 | 192.168.30.21 |
| k3s-worker1 | Worker | pve2 | 192.168.30.22 |
| k3s-worker2 | Worker | pve3 | 192.168.30.23 |

## VM Specs

- OS: Rocky Linux 9.7 Minimal
- CPU: 2 cores each
- RAM: 4GB (control plane), 6GB (workers)
- Disk: 32GB each
- Network: VLAN 30 (192.168.30.0/24)

## Status

- [x] VMs provisioned
- [x] Rocky Linux 9.7 installed
- [x] System updated
- [ ] k3s installed on control plane
- [ ] Workers joined to cluster
- [ ] Traefik configured
- [ ] MetalLB configured
