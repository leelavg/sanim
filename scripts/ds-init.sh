#!/bin/bash
set -euo pipefail

echo "Starting sanim initiator..."

# Use host's iscsiadm via nsenter (Fedora 43 iscsiadm incompatible with RHEL CoreOS kernel)
# Note: nsenter uses host's mount namespace, so DNS resolution must happen before nsenter
ISCSIADM="nsenter -t 1 -m -u -i /usr/sbin/iscsiadm"

# Helper function to resolve DNS name to IP (cluster DNS only works in container namespace)
resolve_host() {
  local hostname="$1"
  getent hosts "$hostname" | awk '{print $1}' | head -1
}

# Removed check_portal - iscsiadm discovery will handle retries

# Trap for cleanup
cleanup() {
  if [ "${FORCE_CLEANUP}" == "true" ]; then
    echo "Signal received, logging out from all sessions..."
    $ISCSIADM --mode node --logoutall=all || true
  else
    echo "Signal received, keeping sessions active (FORCE_CLEANUP=false)"
  fi
}
trap cleanup SIGTERM SIGINT

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

# Function to discover and login to global target
discover_and_login_global() {
  GLOBAL_IQN="${IQN_PREFIX}:global"
  GLOBAL_POD_DNS="global-0.global-service.${NAMESPACE}.svc.cluster.local"

  echo "Resolving $GLOBAL_POD_DNS..."
  GLOBAL_IP=$(resolve_host "$GLOBAL_POD_DNS")
  if [ -z "$GLOBAL_IP" ]; then
    echo "Error: Failed to resolve $GLOBAL_POD_DNS"
    return 1
  fi
  echo "Resolved to $GLOBAL_IP"

  echo "Discovering global target at $GLOBAL_IP..."
  for attempt in {1..5}; do
    if $ISCSIADM --mode discovery --type sendtargets --portal "$GLOBAL_IP" 2>/dev/null; then
      echo "Discovery successful on attempt $attempt"
      break
    fi
    echo "Discovery attempt $attempt failed, retrying..."
    sleep 2
  done

  echo "Logging into global target $GLOBAL_IQN..."
  for attempt in {1..5}; do
    if $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --portal "$GLOBAL_IP" --login 2>/dev/null; then
      echo "Login successful on attempt $attempt"
      # Configure aggressive timeouts for fast failure detection
      $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --portal "$GLOBAL_IP" --op update -n node.conn[0].timeo.noop_out_timeout -v 5 2>/dev/null || true
      $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --portal "$GLOBAL_IP" --op update -n node.session.timeo.replacement_timeout -v 15 2>/dev/null || true
      return 0
    fi
    echo "Login attempt $attempt failed, retrying..."
    sleep 2
  done

  echo "Warning: Failed to login to global target after all retries"
  return 1
}

# Login to global target if enabled
if [ "${INSTALL_GLOBAL}" == "true" ]; then
  GLOBAL_IQN="${IQN_PREFIX}:global"
  # Check if we already have a healthy session via sysfs (pod restart scenario)
  HEALTHY_SESSION=false
  for session in $(nsenter -t 1 -m bash -c "ls -d /sys/class/iscsi_session/session* 2>/dev/null || true"); do
    targetname=$(nsenter -t 1 -m cat "$session/targetname" 2>/dev/null || echo "")
    state=$(nsenter -t 1 -m cat "$session/state" 2>/dev/null || echo "")
    if [ "$targetname" = "$GLOBAL_IQN" ] && [ "$state" = "LOGGED_IN" ]; then
      HEALTHY_SESSION=true
      break
    fi
  done

  if [ "$HEALTHY_SESSION" = "true" ]; then
    echo "Healthy session already exists for $GLOBAL_IQN, skipping login"
  else
    # Cleanup any stale/broken sessions
    echo "No healthy session found, cleaning up stale sessions for $GLOBAL_IQN..."
    $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --logout 2>/dev/null || true
    $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --op delete 2>/dev/null || true
    discover_and_login_global
  fi
fi

# Login to zonal target if enabled (port 3261)
if [ "${INSTALL_ZONAL}" == "true" ]; then
  LOCAL_ZONE_IQN="${IQN_PREFIX}:${LOCAL_ZONE}"
  ZONAL_SVC="zonal-service.${NAMESPACE}.svc.cluster.local"
  ZONAL_PORT="3261"

  echo "Discovering zonal targets at $ZONAL_SVC:$ZONAL_PORT..."
  IPS=$(getent hosts "$ZONAL_SVC" | awk '{print $1}')
  ZONAL_LOGIN_SUCCESS=false

  for IP in $IPS; do
    echo "Checking portal $IP:$ZONAL_PORT for zone $LOCAL_ZONE..."

    # Pre-check: ensure portal is listening before discovery
    if ! timeout 1 bash -c "cat < /dev/tcp/${IP}/${ZONAL_PORT}" 2>/dev/null; then
      echo "Portal $IP:$ZONAL_PORT not listening, skipping..."
      continue
    fi

    # Use || true to continue if this portal is unready
    if $ISCSIADM --mode discovery --type sendtargets --portal "$IP:$ZONAL_PORT" 2>/dev/null | grep -q "$LOCAL_ZONE_IQN"; then
      echo "Found matching zone target at $IP:$ZONAL_PORT, logging in..."
      for attempt in {1..5}; do
        if $ISCSIADM --mode node --targetname "$LOCAL_ZONE_IQN" --portal "$IP:$ZONAL_PORT" --login 2>/dev/null; then
          echo "Login successful on attempt $attempt"
          ZONAL_LOGIN_SUCCESS=true
          break 2
        fi
        echo "Login attempt $attempt failed, retrying..."
        sleep 2
      done
    else
      echo "Portal $IP:$ZONAL_PORT ready but no matching zone, trying next..."
    fi
  done

  if [ "$ZONAL_LOGIN_SUCCESS" = false ]; then
    echo "Warning: Failed to login to zonal target for zone $LOCAL_ZONE after checking all portals"
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
    # Check sysfs for healthy session
    HEALTHY_SESSION=false
    for session in $(nsenter -t 1 -m bash -c "ls -d /sys/class/iscsi_session/session* 2>/dev/null || true"); do
      targetname=$(nsenter -t 1 -m cat "$session/targetname" 2>/dev/null || echo "")
      state=$(nsenter -t 1 -m cat "$session/state" 2>/dev/null || echo "")
      if [ "$targetname" = "$GLOBAL_IQN" ] && [ "$state" = "LOGGED_IN" ]; then
        HEALTHY_SESSION=true
        break
      fi
    done

    if [ "$HEALTHY_SESSION" = "false" ]; then
      echo "$(date): Global session unhealthy or missing, cleaning up..."
      $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --logout 2>/dev/null || true
      $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --op delete 2>/dev/null || true
      echo "$(date): Rediscovering and logging in..."
      discover_and_login_global || echo "Failed to re-establish global session"
    fi
  fi

  sleep 10
done
