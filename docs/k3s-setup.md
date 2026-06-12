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

  ## Firewall Configuration

Rocky Linux ships with firewalld enabled, and k3s needs more than the
default openings. The k3s docs actually recommend just disabling firewalld,
but I wanted to keep it on and learn the rules instead.

Ports opened on the control plane:

| Port | Protocol | Purpose |
|------|----------|---------|
| 6443 | TCP | Kubernetes API server |
| 6444 | TCP | k3s supervisor |
| 10250 | TCP | Kubelet (logs, exec, metrics) |
| 8472 | UDP | Flannel VXLAN (pod network between nodes) |

Workers only need 10250 and 8472 — they initiate connections to the
control plane, so 6443/6444 stay closed on them.

```bash
firewall-cmd --permanent --add-port=10250/tcp
firewall-cmd --permanent --add-port=8472/udp
firewall-cmd --reload
```

k3s internal networks also need to be trusted on every node, otherwise
firewalld drops the cluster's own traffic and things like CoreDNS fail
in ways that are hard to trace:

```bash
firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
firewall-cmd --reload
```

10.42.0.0/16 is the pod network, 10.43.0.0/16 is the service network.

Skipped ports 2379-2380 (etcd) — only needed for HA clusters with
embedded etcd. Single control plane uses SQLite.

## Status

- [x] VMs provisioned
- [x] Rocky Linux 9.7 installed
- [x] System updated
- [x] k3s installed on control plane
- [x] Workers joined to cluster
- [x] Firewall ports opened
- [ ] MetalLB configured
- [ ] Traefik configured
- [ ] Longhorn storage configured
- [ ] ArgoCD installed
- [ ] Grafana + Prometheus installed
- [ ] Vaultwarden installed
