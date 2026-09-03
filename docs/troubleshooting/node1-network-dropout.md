# Node 1 (pve1)  NIC drops off the network, only a reboot recovers it

**Status:** Fixed 2026-08-21, soak passed 2026-09-02 under sustained load
**First logged:** 2026-08-21

## Symptom

- pve1 (Lenovo ThinkCentre Tiny, Proxmox host, 192.168.20.11) becomes completely unreachable.
- No SSH, no ICMP reply, Proxmox web UI on :8006 does not load.
- Only a restart recovers it. Host OS stays alive throughout  shutdown was clean and orderly.

## Root cause

Intel **I219-V** onboard NIC (`00:1f.6`, driver `e1000e`, interface `nic0`) wedges its
transmit ring:

```
e1000e 0000:00:1f.6 nic0: Detected Hardware Unit Hang:
  TDH <8b>   TDT <99>
  next_to_use <99>   next_to_clean <8b>
  next_to_watch.status <0>
```

TDH (head) is stuck at 0x8b while TDT (tail) sits at 0x99 14 descriptors queued for
transmit that the hardware never completes, and `next_to_watch.status 0` means the
descriptor was never written back. The NIC can still receive; it cannot transmit, so
the host is invisible on the network.

This is a long-standing, well-documented `e1000e` defect on I219 chipsets, generally
triggered by TCP/generic segmentation offload interacting with PCIe ASPM power
management and Energy Efficient Ethernet.

## Timeline of the last occurrence

- **Aug 12 17:37** — boot
- **Aug 15 00:42** — hardware unit hangs begin, repeating every 2 seconds
- **Aug 21 18:11** — still hanging at time of manual reboot

**The node was off the network for six days before it was noticed.** No alert fired.
The driver never successfully reset the adapter on its own.

## Cluster impact

Corosync logged `[WD] Watchdog not enabled by configuration` Proxmox HA is not armed
on this node. That is why it sat dead instead of self-fencing and rebooting.

Cluster was healthy both before and after the fix: 3 nodes, 3 votes, quorate.
Ring ID advanced 1.a1 → 1.aa across the reboot, which is normal membership churn.

## Fix (ranked  apply in order, verify before moving on)

### 1. Disable segmentation/receive offloads — APPLIED 2026-08-21

Highest-yield, no reboot, fully reversible.

```
ethtool -K nic0 tso off gso off gro off
ethtool -k nic0 | grep -E 'tcp-segmentation|generic-segmentation|generic-receive'
```

Persisted via `/etc/systemd/system/nic0-offload-fix.service`:

```
[Unit]
Description=Disable e1000e offloads on nic0 (I219-V hardware unit hang workaround)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -K nic0 tso off gso off gro off
ExecStart=-/usr/sbin/ethtool --set-eee nic0 eee off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Cost: a few percent CPU on sustained 1 Gbps transfers. Irrelevant on this hardware.

### 2. Disable EEE — COVERED host-side

`ethtool --set-eee nic0 eee off` succeeded. EEE is negotiated between link partners, so
the switch side is unnecessary. Confirmed post-reboot: `EEE status: disabled`.

### 3. Disable PCIe ASPM — NOT APPLIED, held in reserve

Only if the offload fix fails to hold. Requires a reboot. **Check the bootloader first** —
this node is ZFS-root:

```
proxmox-boot-tool status
```

- systemd-boot → add `pcie_aspm=off` to `/etc/kernel/cmdline`, then `proxmox-boot-tool refresh`
- GRUB → add to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then `update-grub`

Editing the wrong one means the parameter silently never applies.

### 4. Lenovo BIOS update

Several ThinkCentre BIOS releases address I219 link/power bugs. Last resort do it
with a monitor attached and after backing up `/etc/pve`.

## Verification

Post-reboot, 2026-08-21:

- `tcp-segmentation-offload: off`, `generic-segmentation-offload: off`, `generic-receive-offload: off`
- `EEE status: disabled`
- `nic0-offload-fix.service` — `active (exited)`
- `pvecm status` — 3/3 votes, quorate
- `journalctl -b | grep -c 'Hardware Unit Hang'` — **0**

Recheck command:

```
journalctl -b | grep -c 'Hardware Unit Hang'
```

**Soak closed 2026-09-02.** The original failure interval was ~3 days from boot. The fix
held for 12 days, and then through a Longhorn deployment plus a full monitoring stack —
the heaviest sustained load this node has carried since the fix — with a hang count still
at 0. Calling it resolved.

## What the fix did not address

A six-day silent outage was the real failure here, and disabling offloads does nothing
about detection. Uptime Kuma now monitors all three Proxmox hosts by ICMP and HTTPS.
Still open: an external check that can outlive the node it runs on.

## Do not touch

- Do not reinstall Proxmox or remove/re-add the node from the cluster.
- Do not apply the ASPM change on top of the offload fix; stacking both means never
  knowing which one worked.
- Do not enable HA fencing on this node until the NIC has a longer track record; a
  flapping NIC plus armed fencing means reboot loops.

## Hardware reference (pve1)

- Intel I219-V onboard NIC, `e1000e`, interface `nic0`, bridged to `vmbr0`
- Crucial MX500 1TB SATA (`/dev/sda`) + Samsung MZVLB256HAHQ 256GB NVMe
- Wireless `wlp2s0` present but DOWN
- VM 301 `k3s-control` — 4 vCPU / 8GB / 32GB boot disk

## Change log

- 2026-08-21: Root cause found — `e1000e` Detected Hardware Unit Hang on I219-V, TX ring
  wedged since Aug 15.
- 2026-08-21: Offloads disabled and persisted via systemd unit; EEE disabled host-side.
  Cluster confirmed quorate.
- 2026-08-21: Reboot verification passed — settings persisted, hang count 0.
- 2026-09-02: Soak closed. Hang count 0 through Longhorn + monitoring deployment.
