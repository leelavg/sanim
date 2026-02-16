#!/bin/bash
set -euo pipefail

echo "Starting sanim global target..."

# Trap handler for graceful shutdown
cleanup() {
  echo "Received termination signal, cleaning up target..."
  IQN="${IQN_PREFIX}:global"

  # Delete IQN (this cascades to TPG, LUNs, and backstores)
  if [ -d "/sys/kernel/config/target/iscsi/${IQN}" ]; then
    targetcli /iscsi delete "$IQN" 2>/dev/null || true
  fi

  # Clean up any orphaned backstores
  for i in $(seq 0 $((GLOBAL_DISK_COUNT - 1))); do
    targetcli /backstores/block delete "lun$i" 2>/dev/null || true
  done

  exit 0
}
trap cleanup SIGTERM SIGINT

# Mount configfs FIRST, then load modules
mount -t configfs none /sys/kernel/config 2>/dev/null || true

# Load kernel modules in correct order
modprobe target_core_mod || true
modprobe target_core_iblock || true
modprobe iscsi_target_mod || true

# Give kernel time to initialize
sleep 2

# Idempotent target creation - only create if not exists
IQN="${IQN_PREFIX}:global"

# Discover LUNs
LUNS=($(ls /dev/global-* 2>/dev/null | sort -V || true))
if [ ${#LUNS[@]} -eq 0 ]; then
  echo "Error: No LUNs found matching /dev/global-*"
  exit 1
fi

# Validate LUN count matches expected
EXPECTED_COUNT=${GLOBAL_DISK_COUNT}
if [ ${#LUNS[@]} -ne $EXPECTED_COUNT ]; then
  echo "Warning: Found ${#LUNS[@]} LUNs but expected $EXPECTED_COUNT"
  echo "Discovered LUNs: ${LUNS[@]}"
fi

# Clean up existing target and backstores
if [ -d "/sys/kernel/config/target/iscsi/${IQN}" ]; then
  echo "Cleaning up existing target: $IQN"
  targetcli /iscsi delete "$IQN" 2>/dev/null || true

  # Clean up backstores after IQN is deleted
  for i in $(seq 0 $((GLOBAL_DISK_COUNT - 1))); do
    targetcli /backstores/block delete "lun$i" 2>/dev/null || true
  done
fi

echo "Creating target: $IQN"
targetcli /iscsi create "$IQN"

# Enable the TPG (this actually binds the network portal and starts listening)
targetcli /iscsi/$IQN/tpg1 enable

# Configure LUNs
for i in "${!LUNS[@]}"; do
  LUN_PATH="${LUNS[$i]}"
  targetcli /backstores/block create "lun$i" "$LUN_PATH"
  targetcli /iscsi/$IQN/tpg1/luns create "/backstores/block/lun$i"
done

# Disable authentication
targetcli /iscsi/$IQN/tpg1/acls delete ALL 2>/dev/null || true
targetcli /iscsi/$IQN/tpg1 set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1 cache_dynamic_acls=1

echo "Global target configured: $IQN with ${#LUNS[@]} LUNs"
targetcli /iscsi ls

echo "Target ready and listening on port 3260"
ss -tlnp | grep 3260 || echo "Warning: Port 3260 not listening"

# Keep running (sleep infinity allows proper signal handling)
sleep infinity & wait
