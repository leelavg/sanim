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

# Function to check if portal is ready
check_portal() {
  local target="$1"
  local max_attempts="${2:-10}"

  for attempt in $(seq 1 $max_attempts); do
    if timeout 1 bash -c "cat < /dev/tcp/${target}/3260" 2>/dev/null; then
      echo "Portal $target is listening (attempt $attempt)"
      return 0
    fi
    echo "Portal $target not ready, attempt $attempt/$max_attempts..."
    sleep 3
  done

  echo "Warning: Portal $target not reachable after $max_attempts attempts"
  return 1
}

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

# Login to global target if enabled
if [ "${INSTALL_GLOBAL}" == "true" ]; then
  GLOBAL_IQN="${IQN_PREFIX}:global"
  GLOBAL_SVC="global-service.${NAMESPACE}.svc.cluster.local"

  echo "Resolving $GLOBAL_SVC..."
  GLOBAL_IP=$(resolve_host "$GLOBAL_SVC")
  if [ -z "$GLOBAL_IP" ]; then
    echo "Error: Failed to resolve $GLOBAL_SVC"
  else
    echo "Resolved to $GLOBAL_IP"

    echo "Waiting for global target portal to be ready..."
    check_portal "$GLOBAL_IP" || true

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
    LOGIN_SUCCESS=false
    for attempt in {1..5}; do
      if $ISCSIADM --mode node --targetname "$GLOBAL_IQN" --portal "$GLOBAL_IP" --login 2>/dev/null; then
        echo "Login successful on attempt $attempt"
        LOGIN_SUCCESS=true
        break
      fi
      echo "Login attempt $attempt failed, retrying..."
      sleep 2
    done

    if [ "$LOGIN_SUCCESS" = false ]; then
      echo "Warning: Failed to login to global target after all retries"
    fi
  fi
fi

# Login to zonal target if enabled
if [ "${INSTALL_ZONAL}" == "true" ]; then
  LOCAL_ZONE_IQN="${IQN_PREFIX}:${LOCAL_ZONE}"
  ZONAL_SVC="zonal-service.${NAMESPACE}.svc.cluster.local"

  echo "Discovering zonal targets at $ZONAL_SVC..."
  IPS=$(getent hosts "$ZONAL_SVC" | awk '{print $1}')
  ZONAL_LOGIN_SUCCESS=false

  for IP in $IPS; do
    echo "Checking portal $IP for zone $LOCAL_ZONE..."

    # Pre-check: ensure portal is listening before discovery
    if ! check_portal "$IP" 5; then
      echo "Portal $IP not listening, skipping..."
      continue
    fi

    # Use || true to continue if this portal is unready
    if $ISCSIADM --mode discovery --type sendtargets --portal "$IP" 2>/dev/null | grep -q "$LOCAL_ZONE_IQN"; then
      echo "Found matching zone target at $IP, logging in..."
      for attempt in {1..5}; do
        if $ISCSIADM --mode node --targetname "$LOCAL_ZONE_IQN" --portal "$IP" --login 2>/dev/null; then
          echo "Login successful on attempt $attempt"
          ZONAL_LOGIN_SUCCESS=true
          break 2
        fi
        echo "Login attempt $attempt failed, retrying..."
        sleep 2
      done
    else
      echo "Portal $IP ready but no matching zone, trying next..."
    fi
  done

  if [ "$ZONAL_LOGIN_SUCCESS" = false ]; then
    echo "Warning: Failed to login to zonal target for zone $LOCAL_ZONE after checking all portals"
  fi
fi

echo "iSCSI sessions active:"
$ISCSIADM --mode session || echo "No active sessions"

echo "Block devices:"
lsblk

# Keep running (sleep infinity allows proper signal handling)
sleep infinity & wait
