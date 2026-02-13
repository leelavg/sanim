#!/bin/bash
set -euo pipefail

echo "Starting sanim zonal target..."

# Mount configfs FIRST, then load modules
mount -t configfs none /sys/kernel/config 2>/dev/null || true

# Load kernel modules in correct order
modprobe target_core_mod || true
modprobe target_core_iblock || true
modprobe iscsi_target_mod || true

# Give kernel time to initialize
sleep 2

# Get zone from node-zone-map ConfigMap
NODE_IP="${NODE_IP}"
ZONE=$(grep "^${NODE_IP}=" /etc/zone-map/mapping | cut -d= -f2)
if [ -z "$ZONE" ]; then
  echo "Error: Failed to find zone for node IP ${NODE_IP} in zone mapping"
  exit 1
fi
echo "Detected zone: $ZONE (node IP: $NODE_IP)"

# Clean up only our specific IQN and backstores
IQN="${IQN_PREFIX}:${ZONE}"
if [ -d "/sys/kernel/config/target/iscsi/${IQN}" ]; then
  echo "Cleaning up existing target: $IQN"
  targetcli /iscsi delete "$IQN" 2>/dev/null || true
fi

# Clean up our backstores
for i in $(seq 0 $((ZONAL_DISK_COUNT - 1))); do
  targetcli /backstores/block delete "zonal-lun$i" 2>/dev/null || true
done

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

# Delete default portal and create on port 3261 to avoid conflict with global (port 3260)
targetcli /iscsi/$IQN/tpg1/portals delete ::0 3260 2>/dev/null || true
targetcli /iscsi/$IQN/tpg1/portals create ::0 3261

# Enable the TPG (this starts the listener)
targetcli /iscsi/$IQN/tpg1 enable

# Configure LUNs
for i in "${!LUNS[@]}"; do
  LUN_PATH="${LUNS[$i]}"
  targetcli /backstores/block create "zonal-lun$i" "$LUN_PATH"
  targetcli /iscsi/$IQN/tpg1/luns create "/backstores/block/zonal-lun$i"
done

# Disable authentication
targetcli /iscsi/$IQN/tpg1/acls delete ALL 2>/dev/null || true
targetcli /iscsi/$IQN/tpg1 set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1 cache_dynamic_acls=1

echo "Zonal target configured: $IQN with ${#LUNS[@]} LUNs"
targetcli /iscsi ls

# Save configuration for persistence
targetcli saveconfig

echo "Target ready and listening on port 3261"
ss -tlnp | grep 3261 || echo "Warning: Port 3261 not listening"

# Keep running (sleep infinity allows proper signal handling)
sleep infinity & wait
