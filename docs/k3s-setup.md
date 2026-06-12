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

## MetalLB

k3s ships with its own load balancer (ServiceLB) and a bundled Traefik
install. I disabled both — anything k3s manages on its own lives outside
my control and outside this repo, and the end goal is everything defined
in Git. MetalLB replaces ServiceLB, and Traefik will get reinstalled
later via Helm where I own the config.

Disabled the bundled components on the control plane:

```bash
cat > /etc/rancher/k3s/config.yaml << 'EOF'
disable:
  - servicelb
  - traefik
EOF
systemctl restart k3s
```

k3s reads that config file at startup like command-line flags, and on
restart it cleaned up the old traefik and svclb pods on its own.

MetalLB speakers gossip with each other over port 7946 to coordinate
which node announces which IP, so this got opened on all three nodes:

```bash
firewall-cmd --permanent --add-port=7946/tcp
firewall-cmd --permanent --add-port=7946/udp
firewall-cmd --reload
```

Installed MetalLB v0.15.2 and gave it a pool of addresses on VLAN 30:

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.2/config/manifests/metallb-native.yaml
```

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: vlan30-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.30.200-192.168.30.220
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: vlan30-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - vlan30-pool
```

The pool is the range MetalLB is allowed to hand out (kept outside the
DHCP range on VLAN 30). The L2Advertisement makes a speaker pod answer
ARP for whatever IPs get assigned, so the rest of the network knows
where to send traffic.

Verified with a throwaway nginx deployment exposed as a LoadBalancer
service — it pulled 192.168.30.201 from the pool and loaded from a
browser on the LAN, across VLANs. Note it grabbed .201, not .200 —
MetalLB doesn't assign sequentially, it just picks a free address.
Deleted the test after.

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
