#!/usr/bin/env bash
set -uo pipefail

DISK_EXPECTED=1
[[ "${1:-}" == "--no-disk" ]] && DISK_EXPECTED=0

LH_PATH="/var/lib/longhorn"
FAIL=0
WARN=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN + 1)); }
sect() { printf '\n\033[1m%s\033[0m\n' "$1"; }

printf '\033[1mLonghorn preflight — %s (%s)\033[0m\n' "$(hostname)" \
  "$([[ $DISK_EXPECTED -eq 1 ]] && echo 'storage node' || echo 'no-disk node')"

sect "Required packages"
for b in iscsiadm mount.nfs4 cryptsetup findmnt lsblk; do
  if command -v "$b" >/dev/null 2>&1; then
    pass "$b"
  else
    fail "$b missing"
  fi
done

sect "iSCSI initiator"
if systemctl is-enabled iscsid >/dev/null 2>&1; then
  pass "iscsid enabled at boot"
else
  fail "iscsid not enabled at boot"
fi
if systemctl is-active iscsid >/dev/null 2>&1; then
  pass "iscsid running"
else
  fail "iscsid not running"
fi
if [[ -f /etc/iscsi/initiatorname.iscsi ]] && grep -q 'InitiatorName=iqn' /etc/iscsi/initiatorname.iscsi; then
  pass "initiatorname.iscsi has an IQN"
else
  fail "/etc/iscsi/initiatorname.iscsi missing or has no IQN"
fi

sect "Kernel modules"
for m in iscsi_tcp dm_crypt; do
  if lsmod | grep -q "^${m}\b" || modprobe "$m" 2>/dev/null; then
    pass "$m loaded"
  else
    fail "$m not loadable"
  fi
done
if [[ -f /etc/modules-load.d/longhorn.conf ]]; then
  pass "modules-load.d/longhorn.conf present"
else
  warn "no /etc/modules-load.d/longhorn.conf — modules will not reload at boot"
fi

sect "multipathd"
if systemctl is-active multipathd >/dev/null 2>&1; then
  if [[ -f /etc/multipath.conf ]] && grep -qE 'devnode\s+"\^sd\[a-z\]' /etc/multipath.conf; then
    pass "multipathd active, sd devices blacklisted"
  else
    fail "multipathd active and sd devices not blacklisted — volumes will hang in 'attaching'"
  fi
else
  pass "multipathd not running"
fi

sect "Longhorn data path"
if [[ $DISK_EXPECTED -eq 0 ]]; then
  if [[ -d "$LH_PATH" ]]; then
    warn "$LH_PATH exists on a node that should host no replicas"
  else
    pass "no $LH_PATH, as expected"
  fi
else
  if findmnt -n "$LH_PATH" >/dev/null 2>&1; then
    SRC=$(findmnt -no SOURCE "$LH_PATH")
    FST=$(findmnt -no FSTYPE "$LH_PATH")
    pass "$LH_PATH is a separate mount ($SRC, $FST)"

    UUID=$(blkid -s UUID -o value "$SRC" 2>/dev/null || true)
    if [[ -n "$UUID" ]] && grep -q "$UUID" /etc/fstab; then
      pass "mount is in /etc/fstab by UUID"
    elif grep -qE "[[:space:]]${LH_PATH}[[:space:]]" /etc/fstab; then
      warn "in /etc/fstab but not by UUID — device names can reorder"
    else
      fail "$LH_PATH is NOT in /etc/fstab — will not survive a reboot"
    fi

    AVAIL_G=$(df -BG --output=avail "$LH_PATH" | tail -1 | tr -dc '0-9')
    if [[ ${AVAIL_G:-0} -ge 50 ]]; then
      pass "${AVAIL_G}G available"
    else
      warn "only ${AVAIL_G}G available"
    fi
  else
    fail "$LH_PATH is not a separate mount — replicas would land on the root filesystem"
  fi
fi

sect "Node state"
if [[ "$(swapon --show --noheadings | wc -l)" -eq 0 ]]; then
  pass "swap off"
else
  warn "swap is on"
fi

if command -v getenforce >/dev/null 2>&1; then
  pass "SELinux: $(getenforce)"
fi

sect "NIC health (e1000e hardware unit hang)"
HANGS=$(journalctl -b 2>/dev/null | grep -c 'Hardware Unit Hang' || true)
HANGS=${HANGS:-0}
if [[ -d /sys/module/e1000e ]]; then
  if [[ "$HANGS" -eq 0 ]]; then
    pass "e1000e loaded, 0 hardware unit hangs this boot"
  else
    fail "$HANGS hardware unit hangs this boot"
  fi
else
  pass "no e1000e on this node — run this on the Proxmox hosts instead"
fi

printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '\033[32mPREFLIGHT PASSED\033[0m  (%d warning(s))\n' "$WARN"
  exit 0
else
  printf '\033[31mPREFLIGHT FAILED\033[0m  %d failure(s), %d warning(s)\n' "$FAIL" "$WARN"
  exit 1
fi
