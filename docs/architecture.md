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
        VM301["k3s-control<br/>VM 301<br/>4GB RAM"]
        H1 --- VM301
    end

    subgraph PVE2["pve2 - ThinkCentre M720q"]
        H2["Proxmox VE 9.1.1<br/>192.168.20.12"]
        VMW1["k3s-worker1<br/>Longhorn disk 100GB"]
        H2 --- VMW1
    end

    subgraph PVE3["pve3 - ThinkCentre M720q"]
        H3["Proxmox VE 9.1.1<br/>192.168.20.13"]
        VMW2["k3s-worker2<br/>Longhorn disk 100GB"]
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
| 30 | k3s services | 192.168.30.0/24 | MetalLB L2 pool |
| 40 | Storage / NAS | 192.168.40.0/24 | Longhorn backup target |
| 50 | Management | 192.168.50.0/24 | Switch and OOB access |

## Cluster and GitOps flow

```mermaid
flowchart LR
    DEV["Local commit"]
    GH["GitHub<br/>KFlowers483/homelab"]
    ARGO["Argo CD<br/>app-of-apps"]

    DEV --> GH
    GH --> ARGO

    subgraph CLUSTER["k3s v1.35.4"]
        ARGO --> TRAEFIK["Traefik<br/>ingress"]
        ARGO --> METAL["MetalLB<br/>VLAN 30 pool"]
        ARGO --> CERT["cert-manager<br/>internal CA"]
        ARGO --> RANCHER["Rancher"]
        ARGO --> LH["Longhorn<br/>replicated storage"]
        ARGO --> MON["kube-prometheus-stack"]
        ARGO --> KUMA["Uptime Kuma"]

        LH -.->|"PVC"| KUMA
        LH -.->|"PVC"| MON
        MON -->|"scrape"| KUMA
    end

    METAL --> TRAEFIK
    CERT -.->|"TLS certs"| TRAEFIK
```

## Storage layout

```mermaid
flowchart TB
    PVC["PVC<br/>uptime-kuma-data-longhorn<br/>ReadWriteOnce"]
    SC["StorageClass: longhorn<br/>reclaimPolicy Retain<br/>replicas 2"]
    VOL["Longhorn Volume"]
    R1["Replica 1<br/>k3s-worker1<br/>/var/lib/longhorn"]
    R2["Replica 2<br/>k3s-worker2<br/>/var/lib/longhorn"]
    BAK["NFS backup target<br/>VLAN 40"]

    PVC --> SC
    SC --> VOL
    VOL --> R1
    VOL --> R2
    VOL -.->|"recurring backup"| BAK
```

## Service endpoints

| Service | Host | Auth |
|---------|------|------|
| Rancher | rancher.home | Built-in |
| Uptime Kuma | uptime.home | Built-in |
| Longhorn | longhorn.home | Traefik basicAuth |
| Grafana | grafana.home | Built-in |
| Prometheus | prometheus.home | Traefik basicAuth |
| Alertmanager | alertmanager.home | Traefik basicAuth |
