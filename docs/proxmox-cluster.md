# Proxmox Cluster Setup

## Nodes
| Node | Hostname | IP | Storage |
|------|----------|----|---------|
| pve1 | pve1.homelab.local | 192.168.20.11 | 512GB NVMe + 1TB SSD |
| pve2 | pve2.homelab.local | 192.168.20.12 | 512GB NVMe |
| pve3 | pve3.homelab.local | 192.168.20.13 | 512GB NVMe |

## Cluster
- Cluster name: `homelab`
- Proxmox version: 9.1.1

## Post-Install Steps
- Disabled enterprise repo, enabled no-subscription repo
- Removed subscription nag screen
- Set timezone to America/New_York
- Enabled VLAN aware on vmbr0 on all nodes
- Node 1 has additional LVM-thin pool `data-ssd` on 1TB SSD

## Network
- All nodes on VLAN 20 (192.168.20.0/24)
- vmbr0 is VLAN aware for VM traffic
