# pve1 drops off the network, only a reboot brings it back

Fixed Aug 21. Soak closed Sep 2, then proven again Sep 4 under real storage
load. Calling this one done.

## Symptom

pve1 (192.168.20.11) goes completely unreachable. No SSH, no ping, Proxmox web
UI on :8006 doesn't load. Only a restart recovers it. The host OS stays alive
the whole time, shutdown was clean and orderly, so it's not a crash.

## What was actually happening

The onboard Intel I219-V NIC wedges its transmit ring:

```
e1000e 0000:00:1f.6 nic0: Detected Hardware Unit Hang:
  TDH <8b>   TDT <99>
  next_to_use <99>   next_to_clean <8b>
  next_to_watch.status <0>
```

TDH is the ring head, TDT is the tail. Head stuck at 0x8b, tail at 0x99, so 14
descriptors are queued to transmit that the hardware never completes.
`next_to_watch.status 0` means the descriptor was never written back. The NIC
can still receive fine. It just can't send, so the host is invisible on the
network while being perfectly alive.

This is a long-standing e1000e bug on I219 chipsets. It's usually triggered by
TCP/generic segmentation offload interacting with PCIe ASPM power management
and Energy Efficient Ethernet.

## Timeline of the last occurrence

- Aug 12 17:37, boot
- Aug 15 00:42, hardware unit hangs start, repeating every 2 seconds
- Aug 21 18:11, still hanging when I finally rebooted it

That's six days off the network before I noticed. No alert fired. The driver
never managed to reset the adapter on its own. The outage isn't the
embarrassing part, the six days is.

## Cluster impact

Corosync logged `[WD] Watchdog not enabled by configuration`. Proxmox HA isn't
armed on this node, which is why it sat there dead instead of fencing itself
and rebooting.

Cluster stayed healthy either side of the fix: 3 nodes, 3 votes, quorate. Ring
ID went 1.a1 to 1.aa across the reboot, which is normal membership churn.

## Fix

Ranked. Apply in order, verify before moving to the next.

### 1. Disable segmentation and receive offloads (applied Aug 21)

Highest yield, no reboot needed, fully reversible.

```bash
ethtool -K nic0 tso off gso off gro off
ethtool -k nic0 | grep -E 'tcp-segmentation|generic-segmentation|generic-receive'
```

Made it persistent with `/etc/systemd/system/nic0-offload-fix.service`:

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

Costs a few percent CPU on sustained gigabit transfers. Irrelevant on this
hardware.

### 2. Disable EEE (covered host-side)

`ethtool --set-eee nic0 eee off` worked. EEE is negotiated between link
partners so the switch side isn't necessary. Confirmed after reboot:
`EEE status: disabled`.

### 3. Disable PCIe ASPM (not applied, holding in reserve)

Only if the offload fix stops holding. Needs a reboot. Check the bootloader
first, this node is ZFS-root:

```bash
proxmox-boot-tool status
```

- systemd-boot: add `pcie_aspm=off` to `/etc/kernel/cmdline`, then
  `proxmox-boot-tool refresh`
- GRUB: add to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then
  `update-grub`

Edit the wrong one and the parameter silently never applies.

### 4. Lenovo BIOS update

Several ThinkCentre BIOS releases address I219 link and power bugs. Last
resort. Do it with a monitor attached and after backing up `/etc/pve`.

## Verification

After the reboot on Aug 21:

- tcp-segmentation-offload: off, generic-segmentation-offload: off,
  generic-receive-offload: off
- EEE status: disabled
- `nic0-offload-fix.service` active (exited)
- `pvecm status` 3/3 votes, quorate
- `journalctl -b | grep -c 'Hardware Unit Hang'` returned 0

Recheck command:

```bash
journalctl -b | grep -c 'Hardware Unit Hang'
```

## Soak, and why it's closed

The original failure interval was about 3 days from boot. The fix held for 12
clean days, which was the original bar.

Then on Sep 2 through 4 I deployed Longhorn and a full monitoring stack onto
this cluster, which put real sustained transfer across the node network for
the first time since the fix: replica rebuilds, a worker reboot with automatic
recovery, and cross-node storage traffic on 1GbE. Hang count stayed at 0
through all of it.

That's a better test than waiting. Closing it.

## What the fix didn't address

Disabling offloads does nothing about detection, and the six-day silent outage
was the real failure. Uptime Kuma now monitors all three Proxmox hosts by ICMP
and HTTPS. Still open: an external check that can outlive the node it runs on.
A monitor that dies with the thing it's watching isn't a monitor.

## Don't do these

- Don't reinstall Proxmox or remove and re-add the node from the cluster
- Don't stack the ASPM change on top of the offload fix, you'll never know
  which one worked
- Don't arm HA fencing on this node until the NIC has a longer track record.
  A flapping NIC plus fencing is a reboot loop.

## Hardware reference (pve1)

- Intel I219-V onboard NIC, e1000e driver, interface `nic0`, bridged to `vmbr0`
- Crucial MX500 1TB SATA (`/dev/sda`) plus Samsung MZVLB256HAHQ 256GB NVMe
- Wireless `wlp2s0` present but down
- VM 301 `k3s-control`, 4 vCPU / 8GB / 32GB boot disk

## Change log

- Aug 21: root cause found. e1000e hardware unit hang on I219-V, TX ring wedged
  since Aug 15.
- Aug 21: offloads disabled and persisted via systemd unit, EEE disabled
  host-side, cluster confirmed quorate.
- Aug 21: reboot verification passed, settings persisted, hang count 0.
- Sep 2: 12 clean days.
- Sep 4: hang count still 0 after Longhorn deployment, replica rebuilds and a
  node failure test. Closed.
