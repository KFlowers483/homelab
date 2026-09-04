# Architecture

## Physical and network topology

```mermaid
flowchart TB
    WAN["Internet"]
    FW["Netgate SG-3100<br/>pfSense<br/>inter-VLAN routing + firewall"]
    SW["Netgear GS308E<br/>802.1Q trunk"]

    WAN --> FW
    FW --> SW

    subgraph PVE1["pve1 - ThinkCentre M720q"]
        H1["Proxmox VE 9.1.1<br/>192.168.20.11<br/>1TB SSD + 256GB NVMe"]
        VM301["k3s-control<br/>VM 301<br/>4 vCPU / 8GB"]
        H1 --- VM301
    end

    subgraph PVE2["pve2 - ThinkCentre M720q"]
        H2["Proxmox VE 9.1.1<br/>192.168.20.12"]
        VMW1["k3s-worker1<br/>VM 302<br/>4 vCPU / 8GB<br/>+100GB Longhorn disk"]
        H2 --- VMW1
    end

    subgraph PVE3["pve3 - ThinkCentre M720q"]
        H3["Proxmox VE 9.1.1<br/>192.168.20.13"]
        VMW2["k3s-worker2<br/>VM 303<br/>4 vCPU / 8GB<br/>+100GB Longhorn disk"]
        H3 --- VMW2
    end

    SW --> PVE1
    SW --> PVE2
    SW --> PVE3
```

## VLAN plan

| VLAN | Purpose | Subnet | Notes |
|------|---------|--------|-------|
| 10 | LAN / general devices | 192.168.10.0/24 | |
| 20 | Proxmox cluster | 192.168.20.0/24 | pve1 .11, pve2 .12, pve3 .13 |
| 30 | k3s nodes and services | 192.168.30.0/24 | nodes .21-.23, MetalLB pool .200-.220 |
| 40 | Storage / NAS | 192.168.40.0/24 | Longhorn backup target, planned |
| 50 | Management | 192.168.50.0/24 | Switch and OOB access |

## Cluster and GitOps flow

```mermaid
flowchart LR
    DEV["Local commit"]
    GH["GitHub<br/>KFlowers483/homelab"]
    ARGO["ArgoCD<br/>app-of-apps"]

    DEV --> GH
    GH --> ARGO

    subgraph CLUSTER["k3s v1.35.4"]
        ARGO --> TRAEFIK["Traefik<br/>ingress"]
        ARGO --> METAL["MetalLB<br/>VLAN 30 pool"]
        ARGO --> CERT["cert-manager<br/>internal CA"]
        ARGO --> RANCHER["Rancher"]
        ARGO --> LH["Longhorn<br/>2 replicas"]
        ARGO --> MON["kube-prometheus-stack"]
        ARGO --> KUMA["Uptime Kuma"]
        ARGO --> VAULT["Vaultwarden"]

        LH -.->|"PVC"| KUMA
        LH -.->|"PVC"| MON
        MON -->|"scrape"| KUMA
    end

    METAL --> TRAEFIK
    CERT -.->|"TLS certs"| TRAEFIK
```

## Storage layout

Longhorn runs on the two workers only. The control plane is deliberately
excluded with `createDefaultDiskLabeledNodes: true` and no label, so etcd and
the API server never compete with replica traffic.

```mermaid
flowchart TB
    PVC["PVC<br/>uptime-kuma-data-longhorn<br/>ReadWriteOnce"]
    SC["StorageClass: longhorn<br/>reclaimPolicy Retain<br/>replicas 2"]
    VOL["Longhorn Volume"]
    R1["Replica 1<br/>k3s-worker1<br/>/var/lib/longhorn"]
    R2["Replica 2<br/>k3s-worker2<br/>/var/lib/longhorn"]
    BAK["NFS backup target<br/>VLAN 40 (planned)"]

    PVC --> SC
    SC --> VOL
    VOL --> R1
    VOL --> R2
    VOL -.->|"recurring backup"| BAK
```

`local-path` is still the cluster default StorageClass. `longhorn` is opt-in
per PVC, so nothing lands on replicated storage by accident.

Each worker disk is 100GB, mounted at `/var/lib/longhorn` by UUID in
`/etc/fstab`. Longhorn reserves 25% of each, leaving roughly 70GB schedulable
per node.

## Service endpoints

| Service | Host | Auth | TLS |
|---------|------|------|-----|
| Rancher | rancher.home | Built-in | Rancher CA |
| Uptime Kuma | uptime.home | Built-in | no |
| Vaultwarden | vault.home | Built-in | homelab CA |
| Longhorn | longhorn.home | Traefik basicAuth | homelab CA |
| Grafana | grafana.home | Built-in | homelab CA |
| Prometheus | prometheus.home | Traefik basicAuth | homelab CA |
| Alertmanager | alertmanager.home | Traefik basicAuth | homelab CA |

## Host-level config not in Git

These are node changes with no manifest behind them. Ansible candidates.

Longhorn prerequisites, all three nodes:

```bash
dnf install -y iscsi-initiator-utils nfs-utils cryptsetup
systemctl enable --now iscsid
printf 'iscsi_tcp\ndm_crypt\n' > /etc/modules-load.d/longhorn.conf
```

firewalld rule for node-exporter, all three nodes. Without it Prometheus can
only scrape whichever node it happens to be running on:

```bash
firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=192.168.30.0/24 port port=9100 protocol=tcp accept'
firewall-cmd --reload
```
