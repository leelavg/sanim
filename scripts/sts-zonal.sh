#!/bin/bash
set -euo pipefail

echo "Starting sanim zonal target..."

# Load kernel modules and mount configfs
modprobe target_core_mod || true
modprobe iscsi_target_mod || true
mount -t configfs none /sys/kernel/config || true

# Clear existing config (handle locked states gracefully)
targetcli clearconfig confirm=true || {
  echo "Warning: clearconfig failed, attempting forced cleanup..."

  # Try to remove orphaned objects from configfs
  if [ -d /sys/kernel/config/target/iscsi ]; then
    shopt -s nullglob
    for iqn in /sys/kernel/config/target/iscsi/iqn.*; do
      [ -d "$iqn" ] && echo "Removing orphaned IQN: $(basename $iqn)"
      rmdir "$iqn/tpgt_1/acls/"* 2>/dev/null || true
      rmdir "$iqn/tpgt_1/lun/"* 2>/dev/null || true
      rmdir "$iqn/tpgt_1" 2>/dev/null || true
      rmdir "$iqn" 2>/dev/null || true
    done
    shopt -u nullglob
  fi

  if [ -d /sys/kernel/config/target/core ]; then
    shopt -s nullglob
    for backstore in /sys/kernel/config/target/core/iblock_*/*; do
      [ -d "$backstore" ] && echo "Removing orphaned backstore: $(basename $backstore)"
      rmdir "$backstore" 2>/dev/null || true
    done
    shopt -u nullglob
  fi

  targetcli ls || true
}

# Get zone from node-zone-map ConfigMap
NODE_IP="${NODE_IP}"
ZONE=$(grep "^${NODE_IP}=" /etc/zone-map/mapping | cut -d= -f2)
if [ -z "$ZONE" ]; then
  echo "Error: Failed to find zone for node IP ${NODE_IP} in zone mapping"
  exit 1
fi
echo "Detected zone: $ZONE (node IP: $NODE_IP)"

# Discover LUNs
LUNS=($(ls /dev/zonal-* 2>/dev/null | sort -V || true))
if [ ${#LUNS[@]} -eq 0 ]; then
  echo "Error: No LUNs found matching /dev/zonal-*"
  exit 1
fi

# Validate LUN count matches expected
EXPECTED_COUNT=${ZONAL_DISK_COUNT}
if [ ${#LUNS[@]} -ne $EXPECTED_COUNT ]; then
  echo "Warning: Found ${#LUNS[@]} LUNs but expected $EXPECTED_COUNT"
  echo "Discovered LUNs: ${LUNS[@]}"
fi

# Create iSCSI target with zone suffix
IQN="${IQN_PREFIX}:${ZONE}"
targetcli /iscsi create "$IQN"

# Delete default IPv6 portal (keep IPv4 0.0.0.0:3260)
targetcli /iscsi/$IQN/tpg1/portals delete :: 3260 2>/dev/null || true

# Configure LUNs
for i in "${!LUNS[@]}"; do
  LUN_PATH="${LUNS[$i]}"
  targetcli /backstores/block create "lun$i" "$LUN_PATH"
  targetcli /iscsi/$IQN/tpg1/luns create "/backstores/block/lun$i"
done

# Disable authentication
targetcli /iscsi/$IQN/tpg1/acls delete ALL 2>/dev/null || true
targetcli /iscsi/$IQN/tpg1 set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1 cache_dynamic_acls=1

echo "Zonal target configured: $IQN with ${#LUNS[@]} LUNs"
targetcli /iscsi ls

# Keep running (sleep infinity allows proper signal handling)
sleep infinity & wait
