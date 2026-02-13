#!/bin/bash
set -euo pipefail

echo "Starting sanim initiator..."

# Configure SELinux to allow iSCSI on port 3261 (for zonal targets)
# Red Hat Solution: https://access.redhat.com/solutions/5170611
# SELinux only permits port 3260 by default; port 3261 must be explicitly added
# Note: DaemonSet runs on ALL nodes, so this configures both initiator and target nodes
echo "Configuring SELinux for iSCSI port 3261..."
nsenter -t 1 -m -u -i semanage port -a -t iscsi_port_t -p tcp 3261 2>/dev/null || true

# Use host's iscsiadm via nsenter (Fedora 43 iscsiadm incompatible with RHEL CoreOS kernel)
# Note: nsenter uses host's mount namespace, so DNS resolution must happen before nsenter
ISCSIADM="nsenter -t 1 -m -u -i /usr/sbin/iscsiadm"

# Helper function to resolve DNS name to IP (cluster DNS only works in container namespace)
resolve_host() {
  local hostname="$1"
  getent hosts "$hostname" | awk '{print $1}' | head -1
}

# Generic function to check if session is healthy via sysfs
check_session_health() {
  local iqn="$1"
  for session in $(nsenter -t 1 -m bash -c "ls -d /sys/class/iscsi_session/session* 2>/dev/null || true"); do
    targetname=$(nsenter -t 1 -m cat "$session/targetname" 2>/dev/null || echo "")
    state=$(nsenter -t 1 -m cat "$session/state" 2>/dev/null || echo "")
    if [ "$targetname" = "$iqn" ] && [ "$state" = "LOGGED_IN" ]; then
      return 0
    fi
  done
  return 1
}

# Generic function to discover and login to target
discover_and_login() {
  local iqn="$1"
  local pod_dns="$2"
  local port="${3:-3260}"  # Default to 3260 if not specified

  echo "Resolving $pod_dns..."
  local ip=$(resolve_host "$pod_dns")
  if [ -z "$ip" ]; then
    echo "Error: Failed to resolve $pod_dns"
    return 1
  fi
  echo "Resolved to $ip"

  echo "Discovering target at $ip:$port..."
  for attempt in {1..5}; do
    if $ISCSIADM --mode discovery --type sendtargets --portal "$ip:$port" 2>/dev/null; then
      echo "Discovery successful on attempt $attempt"
      break
    fi
    echo "Discovery attempt $attempt failed, retrying..."
    sleep 2
  done

  echo "Logging into target $iqn..."
  for attempt in {1..5}; do
    if $ISCSIADM --mode node --targetname "$iqn" --portal "$ip:$port" --login 2>/dev/null; then
      echo "Login successful on attempt $attempt"
      # Configure aggressive timeouts for fast failure detection
      $ISCSIADM --mode node --targetname "$iqn" --portal "$ip:$port" --op update -n node.conn[0].timeo.noop_out_timeout -v 5 2>/dev/null || true
      $ISCSIADM --mode node --targetname "$iqn" --portal "$ip:$port" --op update -n node.session.timeo.replacement_timeout -v 15 2>/dev/null || true
      return 0
    fi
    echo "Login attempt $attempt failed, retrying..."
    sleep 2
  done

  echo "Warning: Failed to login to $iqn after all retries"
  return 1
}

# Session cleanup: Sessions persist in host kernel across pod restarts
# For cleanup, use the cleanup.sh script which handles both resources and sessions

# Ensure host initiator name is used (avoid container's initiatorname.iscsi)
if [ -f /etc/iscsi/initiatorname.iscsi ]; then
  echo "Using host initiator name: $(cat /etc/iscsi/initiatorname.iscsi)"
fi

# Get local zone from node-zone-map ConfigMap
NODE_IP="${NODE_IP}"
LOCAL_ZONE=$(grep "^${NODE_IP}=" /etc/zone-map/mapping | cut -d= -f2)
if [ -z "$LOCAL_ZONE" ]; then
  echo "Error: Failed to find zone for node IP ${NODE_IP} in zone mapping"
  exit 1
fi
echo "Detected zone: $LOCAL_ZONE (node IP: $NODE_IP)"

# Login to global target if enabled
if [ "${INSTALL_GLOBAL}" == "true" ]; then
  GLOBAL_IQN="${IQN_PREFIX}:global"
  GLOBAL_POD_DNS="global-0.global-service.${NAMESPACE}.svc.cluster.local"

  if check_session_health "$GLOBAL_IQN"; then
    echo "Healthy session already exists for $GLOBAL_IQN, skipping login"
  else
    echo "No healthy session found, cleaning up stale sessions for $GLOBAL_IQN..."
    $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --logout 2>/dev/null || true
    $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --op delete 2>/dev/null || true
    discover_and_login "$GLOBAL_IQN" "$GLOBAL_POD_DNS"
  fi
fi

# Login to zonal target if enabled
if [ "${INSTALL_ZONAL}" == "true" ]; then
  LOCAL_ZONE_IQN="${IQN_PREFIX}:${LOCAL_ZONE}"
  # Zone name may have dots, replace with dashes for DNS-safe service name
  LOCAL_ZONE_SAFE=$(echo "$LOCAL_ZONE" | tr '.' '-')
  ZONAL_POD_DNS="zonal-${LOCAL_ZONE_SAFE}-0.zonal-${LOCAL_ZONE_SAFE}-service.${NAMESPACE}.svc.cluster.local"

  if check_session_health "$LOCAL_ZONE_IQN"; then
    echo "Healthy session already exists for $LOCAL_ZONE_IQN, skipping login"
  else
    echo "No healthy session found, cleaning up stale sessions for $LOCAL_ZONE_IQN..."
    $ISCSIADM --mode node --targetname "$LOCAL_ZONE_IQN" --logout 2>/dev/null || true
    $ISCSIADM --mode node --targetname "$LOCAL_ZONE_IQN" --op delete 2>/dev/null || true
    discover_and_login "$LOCAL_ZONE_IQN" "$ZONAL_POD_DNS" 3261
  fi
fi

echo "Initial iSCSI sessions active:"
$ISCSIADM --mode session || echo "No active sessions"

echo "Block devices:"
lsblk

# Monitor loop: check session health via sysfs and reconnect if needed
echo "Starting session monitor loop (checking every 10s)..."
while true; do
  if [ "${INSTALL_GLOBAL}" == "true" ]; then
    GLOBAL_IQN="${IQN_PREFIX}:global"
    GLOBAL_POD_DNS="global-0.global-service.${NAMESPACE}.svc.cluster.local"

    if ! check_session_health "$GLOBAL_IQN"; then
      echo "$(date): Global session unhealthy or missing, cleaning up..."
      $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --logout 2>/dev/null || true
      $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --op delete 2>/dev/null || true
      echo "$(date): Rediscovering and logging in..."
      discover_and_login "$GLOBAL_IQN" "$GLOBAL_POD_DNS" || echo "Failed to re-establish global session"
    fi
  fi

  if [ "${INSTALL_ZONAL}" == "true" ]; then
    LOCAL_ZONE_IQN="${IQN_PREFIX}:${LOCAL_ZONE}"
    LOCAL_ZONE_SAFE=$(echo "$LOCAL_ZONE" | tr '.' '-')
    ZONAL_POD_DNS="zonal-${LOCAL_ZONE_SAFE}-0.zonal-${LOCAL_ZONE_SAFE}-service.${NAMESPACE}.svc.cluster.local"

    if ! check_session_health "$LOCAL_ZONE_IQN"; then
      echo "$(date): Zonal session unhealthy or missing, cleaning up..."
      $ISCSIADM --mode node --targetname "$LOCAL_ZONE_IQN" --logout 2>/dev/null || true
      $ISCSIADM --mode node --targetname "$LOCAL_ZONE_IQN" --op delete 2>/dev/null || true
      echo "$(date): Rediscovering and logging in..."
      discover_and_login "$LOCAL_ZONE_IQN" "$ZONAL_POD_DNS" 3261 || echo "Failed to re-establish zonal session"
    fi
  fi

  # Use sleep with background process and wait to allow trap to interrupt
  sleep 10 & wait $!
done
