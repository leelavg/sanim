#!/bin/bash
set -euo pipefail

# Source user configuration if exists
[ -f config.env ] && source config.env

# Apply defaults (user values take precedence)
NAMESPACE="${NAMESPACE:-sanim-system}"
INSTALL_GLOBAL="${INSTALL_GLOBAL:-true}"
INSTALL_ZONAL="${INSTALL_ZONAL:-true}"
GLOBAL_DISK_COUNT="${GLOBAL_DISK_COUNT:-2}"
GLOBAL_DISK_SIZE="${GLOBAL_DISK_SIZE:-10Gi}"
GLOBAL_ZONE="${GLOBAL_ZONE:-us-east-1a}"
ZONAL_DISK_COUNT="${ZONAL_DISK_COUNT:-1}"
ZONAL_DISK_SIZE="${ZONAL_DISK_SIZE:-10Gi}"
UNIQUE_ZONE_COUNT="${UNIQUE_ZONE_COUNT:-3}"
IQN_PREFIX="${IQN_PREFIX:-iqn.2026-02.com.thoughtexpo:storage}"
STORAGE_CLASS="${STORAGE_CLASS:-gp3-csi}"
DEVICE_PREFIX="${DEVICE_PREFIX:-sanim}"
IMAGE="${IMAGE:-ghcr.io/leelavg/sanim:latest}"
NODE_LABEL_FILTER="${NODE_LABEL_FILTER:-sanim-node=true}"
FORCE_CLEANUP="${FORCE_CLEANUP:-false}"

# Validation (hard stop before any YAML generation)
if [ "$INSTALL_GLOBAL" == "true" ] && [ -z "$GLOBAL_ZONE" ]; then
  echo "Error: GLOBAL_ZONE must be set when INSTALL_GLOBAL=true" >&2
  echo "Example: GLOBAL_ZONE=us-east-1a" >&2
  exit 1
fi

if [ "$INSTALL_GLOBAL" != "true" ] && [ "$INSTALL_ZONAL" != "true" ]; then
  echo "Error: At least one of INSTALL_GLOBAL or INSTALL_ZONAL must be set to 'true'" >&2
  exit 1
fi

# Entrypoint scripts using quoted heredocs
read -r -d '' STS_GLOBAL_SCRIPT <<'EOF' || true
#!/bin/bash
set -euo pipefail

echo "Starting sanim global target..."

# Load kernel modules and mount configfs
modprobe target_core_mod || true
modprobe iscsi_target_mod || true
mount -t configfs none /sys/kernel/config || true

# Clear existing config (handle locked states gracefully)
targetcli clearconfig confirm=true || {
  echo "Warning: clearconfig failed, attempting forced cleanup..."
  
  # Try to remove orphaned objects from configfs
  if [ -d /sys/kernel/config/target/iscsi ]; then
    for iqn in /sys/kernel/config/target/iscsi/iqn.* 2>/dev/null; do
      [ -d "$iqn" ] && echo "Removing orphaned IQN: $(basename $iqn)"
      rmdir "$iqn/tpgt_1/acls/"* 2>/dev/null || true
      rmdir "$iqn/tpgt_1/lun/"* 2>/dev/null || true
      rmdir "$iqn/tpgt_1" 2>/dev/null || true
      rmdir "$iqn" 2>/dev/null || true
    done
  fi
  
  if [ -d /sys/kernel/config/target/core ]; then
    for backstore in /sys/kernel/config/target/core/iblock_*/* 2>/dev/null; do
      [ -d "$backstore" ] && echo "Removing orphaned backstore: $(basename $backstore)"
      rmdir "$backstore" 2>/dev/null || true
    done
  fi
  
  targetcli ls || true
}

# Discover LUNs
LUNS=($(ls /dev/${DEVICE_PREFIX}-* 2>/dev/null | sort -V || true))
if [ ${#LUNS[@]} -eq 0 ]; then
  echo "Error: No LUNs found matching /dev/${DEVICE_PREFIX}-*"
  exit 1
fi

# Validate LUN count matches expected
EXPECTED_COUNT=${GLOBAL_DISK_COUNT}
if [ ${#LUNS[@]} -ne $EXPECTED_COUNT ]; then
  echo "Warning: Found ${#LUNS[@]} LUNs but expected $EXPECTED_COUNT"
  echo "Discovered LUNs: ${LUNS[@]}"
fi

# Create iSCSI target
IQN="${IQN_PREFIX}:global"
targetcli /iscsi create "$IQN"
targetcli /iscsi/$IQN/tpg1/portals delete 0.0.0.0 3260
targetcli /iscsi/$IQN/tpg1/portals create 0.0.0.0 3260

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

# Keep running (sleep infinity allows proper signal handling)
sleep infinity & wait
EOF

read -r -d '' STS_ZONAL_SCRIPT <<'EOF' || true
#!/bin/bash
set -euo pipefail

echo "Starting sanim zonal target..."

# Load kernel modules and mount configfs
modprobe target_core_mod || true
modprobe iscsi_target_mod || true
mount -t configfs none /sys/kernel/config || true

targetcli clearconfig confirm=true

# Get zone from downward API
ZONE="${POD_ZONE}"

# Discover LUNs
LUNS=($(ls /dev/${DEVICE_PREFIX}-* 2>/dev/null | sort -V || true))
if [ ${#LUNS[@]} -eq 0 ]; then
  echo "Error: No LUNs found matching /dev/${DEVICE_PREFIX}-*"
  exit 1
fi

# Validate LUN count matches expected
EXPECTED_COUNT=${ZONAL_DISK_COUNT}
if [ ${#LUNS[@]} -ne $EXPECTED_COUNT ]; then
  echo "Warning: Found ${#LUNS[@]} LUNs but expected $EXPECTED_COUNT"
  echo "Discovered LUNs: ${LUNS[@]}"
fi

# Create iSCSI target with zone suffix
IQN="${IQN_PREFIX}:zone-${ZONE}"
targetcli /iscsi create "$IQN"
targetcli /iscsi/$IQN/tpg1/portals delete 0.0.0.0 3260
targetcli /iscsi/$IQN/tpg1/portals create 0.0.0.0 3260

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
EOF

read -r -d '' DS_INIT_SCRIPT <<'EOF' || true
#!/bin/bash
set -euo pipefail

echo "Starting sanim initiator..."

# Trap for cleanup
cleanup() {
  if [ "${FORCE_CLEANUP}" == "true" ]; then
    echo "Signal received, logging out from all sessions..."
    iscsiadm --mode node --logoutall=all || true
  else
    echo "Signal received, keeping sessions active (FORCE_CLEANUP=false)"
  fi
}
trap cleanup SIGTERM SIGINT

# Ensure host initiator name is used (avoid container's initiatorname.iscsi)
if [ -f /etc/iscsi/initiatorname.iscsi ]; then
  echo "Using host initiator name: $(cat /etc/iscsi/initiatorname.iscsi)"
fi

# Get local zone from downward API
LOCAL_ZONE="${NODE_ZONE}"

# Login to global target if enabled
if [ "${INSTALL_GLOBAL}" == "true" ]; then
  GLOBAL_IQN="${IQN_PREFIX}:global"
  GLOBAL_SVC="global-service.${NAMESPACE}.svc.cluster.local"
  
  echo "Waiting for global target portal to be ready..."
  for attempt in {1..10}; do
    if timeout 1 bash -c "cat < /dev/tcp/${GLOBAL_SVC}/3260" 2>/dev/null; then
      echo "Portal is listening on attempt $attempt"
      break
    fi
    echo "Portal not ready, attempt $attempt/10..."
    sleep 3
  done
  
  echo "Discovering global target at $GLOBAL_SVC..."
  for attempt in {1..5}; do
    if iscsiadm --mode discovery --type sendtargets --portal "$GLOBAL_SVC" 2>/dev/null; then
      echo "Discovery successful on attempt $attempt"
      break
    fi
    echo "Discovery attempt $attempt failed, retrying..."
    sleep 2
  done
  
  echo "Logging into global target $GLOBAL_IQN..."
  for attempt in {1..5}; do
    if iscsiadm --mode node --targetname "$GLOBAL_IQN" --portal "$GLOBAL_SVC" --login 2>/dev/null; then
      echo "Login successful on attempt $attempt"
      break
    fi
    echo "Login attempt $attempt failed, retrying..."
    sleep 2
  done
fi

# Login to zonal target if enabled
if [ "${INSTALL_ZONAL}" == "true" ]; then
  LOCAL_ZONE_IQN="${IQN_PREFIX}:zone-${LOCAL_ZONE}"
  ZONAL_SVC="zonal-service.${NAMESPACE}.svc.cluster.local"
  
  echo "Discovering zonal targets at $ZONAL_SVC..."
  IPS=$(getent hosts "$ZONAL_SVC" | awk '{print $1}')
  
  for IP in $IPS; do
    echo "Checking portal $IP for zone $LOCAL_ZONE..."
    
    # Pre-check: ensure portal is listening before discovery
    PORTAL_READY=false
    for check in {1..5}; do
      if timeout 1 bash -c "cat < /dev/tcp/${IP}/3260" 2>/dev/null; then
        PORTAL_READY=true
        break
      fi
      sleep 1
    done
    
    if [ "$PORTAL_READY" = false ]; then
      echo "Portal $IP not listening on port 3260, skipping..."
      continue
    fi
    
    # Use || true to continue if this portal is unready
    if iscsiadm --mode discovery --type sendtargets --portal "$IP" 2>/dev/null | grep -q "$LOCAL_ZONE_IQN"; then
      echo "Found matching zone target at $IP, logging in..."
      for attempt in {1..5}; do
        if iscsiadm --mode node --targetname "$LOCAL_ZONE_IQN" --portal "$IP" --login 2>/dev/null; then
          echo "Login successful on attempt $attempt"
          break 2
        fi
        echo "Login attempt $attempt failed, retrying..."
        sleep 2
      done
    else
      echo "Portal $IP ready but no matching zone, trying next..."
    fi
  done
fi

echo "iSCSI sessions active:"
iscsiadm --mode session || echo "No active sessions"

echo "Block devices:"
lsblk

# Keep running (sleep infinity allows proper signal handling)
sleep infinity & wait
EOF

# Start generating resources.yaml
cat > resources.yaml <<YAML
#, Namespace for sanim resources
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sanim

#, ConfigMap containing entrypoint scripts
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: scripts
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sanim
data:
  sts-global.sh: |
$(echo "$STS_GLOBAL_SCRIPT" | sed 's/^/    /')
  sts-zonal.sh: |
$(echo "$STS_ZONAL_SCRIPT" | sed 's/^/    /')
  ds-init.sh: |
$(echo "$DS_INIT_SCRIPT" | sed 's/^/    /')

#, ServiceAccount for sanim pods
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: ${NAMESPACE}

#, Custom SecurityContextConstraints for privileged operations
---
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: sanim-privileged
  labels:
    app.kubernetes.io/name: sanim
allowHostDirVolumePlugin: true
allowHostIPC: false
allowHostNetwork: true
allowHostPID: true
allowHostPorts: false
allowPrivilegedContainer: true
allowedCapabilities:
- '*'
defaultAddCapabilities: null
fsGroup:
  type: RunAsAny
priority: null
readOnlyRootFilesystem: false
requiredDropCapabilities: null
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: RunAsAny
supplementalGroups:
  type: RunAsAny
users:
- system:serviceaccount:${NAMESPACE}:default
volumes:
- '*'

YAML

# Generate Global STS resources if enabled
if [ "$INSTALL_GLOBAL" == "true" ]; then
  cat >> resources.yaml <<YAML
#, StatefulSet for global shared iSCSI target
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: global
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sanim
    app.kubernetes.io/component: target
    sanim.io/type: global
spec:
  serviceName: global-service
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: sanim
      app.kubernetes.io/component: target
      sanim.io/type: global
  template:
    metadata:
      labels:
        app.kubernetes.io/name: sanim
        app.kubernetes.io/component: target
        sanim.io/type: global
    spec:
      serviceAccountName: default
      automountServiceAccountToken: false
      nodeSelector:
        topology.kubernetes.io/zone: ${GLOBAL_ZONE}
      containers:
      - name: target
        image: ${IMAGE}
        command: ["/bin/bash", "/scripts/sts-global.sh"]
        env:
        - name: DEVICE_PREFIX
          value: "${DEVICE_PREFIX}"
        - name: IQN_PREFIX
          value: "${IQN_PREFIX}"
        securityContext:
          privileged: true
        volumeMounts:
        - name: scripts
          mountPath: /scripts
        - name: dev
          mountPath: /dev
          mountPropagation: HostToContainer
        - name: lib-modules
          mountPath: /lib/modules
          readOnly: true
        - name: target-config
          mountPath: /etc/target
        volumeDevices:
YAML

  # Generate volumeDevices for strict LUN mapping
  for i in $(seq 0 $((GLOBAL_DISK_COUNT - 1))); do
    cat >> resources.yaml <<YAML
        - name: ${DEVICE_PREFIX}-$i
          devicePath: /dev/${DEVICE_PREFIX}-$i
YAML
  done

  cat >> resources.yaml <<YAML
        readinessProbe:
          exec:
            command:
            - /bin/bash
            - -c
            - targetcli /iscsi ls | grep -q 'iqn'
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: scripts
        configMap:
          name: scripts
          defaultMode: 0755
      - name: dev
        hostPath:
          path: /dev
      - name: lib-modules
        hostPath:
          path: /lib/modules
      - name: target-config
        emptyDir: {}
  volumeClaimTemplates:
YAML

  # Generate PVC templates for global LUNs
for i in $(seq 0 $((GLOBAL_DISK_COUNT - 1))); do
    cat >> resources.yaml <<YAML
  - metadata:
      name: ${DEVICE_PREFIX}-$i
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: ${STORAGE_CLASS}
      volumeMode: Block
      resources:
        requests:
          storage: ${GLOBAL_DISK_SIZE}
YAML
  done

  cat >> resources.yaml <<YAML

#, Headless Service for global target DNS
---
apiVersion: v1
kind: Service
metadata:
  name: global-service
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sanim
    app.kubernetes.io/component: target
    sanim.io/type: global
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: sanim
    app.kubernetes.io/component: target
    sanim.io/type: global
  ports:
  - name: iscsi
    port: 3260
    targetPort: 3260

YAML
fi

# Generate Zonal STS resources if enabled
if [ "$INSTALL_ZONAL" == "true" ]; then
  cat >> resources.yaml <<YAML
#, StatefulSet for zonal shared-nothing iSCSI targets
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: zonal
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sanim
    app.kubernetes.io/component: target
    sanim.io/type: zonal
spec:
  serviceName: zonal-service
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: sanim
      app.kubernetes.io/component: target
      sanim.io/type: zonal
  template:
    metadata:
      labels:
        app.kubernetes.io/name: sanim
        app.kubernetes.io/component: target
        sanim.io/type: zonal
    spec:
      serviceAccountName: default
      automountServiceAccountToken: false
      containers:
      - name: target
        image: ${IMAGE}
        command: ["/bin/bash", "/scripts/sts-zonal.sh"]
        env:
        - name: DEVICE_PREFIX
          value: "${DEVICE_PREFIX}"
        - name: IQN_PREFIX
          value: "${IQN_PREFIX}"
        - name: POD_ZONE
          valueFrom:
            fieldRef:
              fieldPath: metadata.labels['topology.kubernetes.io/zone']
        securityContext:
          privileged: true
        volumeMounts:
        - name: scripts
          mountPath: /scripts
        - name: dev
          mountPath: /dev
          mountPropagation: HostToContainer
        - name: lib-modules
          mountPath: /lib/modules
          readOnly: true
        - name: target-config
          mountPath: /etc/target
        volumeDevices:
YAML

  # Generate volumeDevices for strict LUN mapping
  for i in $(seq 0 $((ZONAL_DISK_COUNT - 1))); do
    cat >> resources.yaml <<YAML
        - name: ${DEVICE_PREFIX}-$i
          devicePath: /dev/${DEVICE_PREFIX}-$i
YAML
  done

  cat >> resources.yaml <<YAML
        readinessProbe:
          exec:
            command:
            - /bin/bash
            - -c
            - targetcli /iscsi ls | grep -q 'iqn'
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: scripts
        configMap:
          name: scripts
          defaultMode: 0755
      - name: dev
        hostPath:
          path: /dev
      - name: lib-modules
        hostPath:
          path: /lib/modules
      - name: target-config
        emptyDir: {}
  volumeClaimTemplates:
YAML

  # Generate PVC templates for zonal LUNs
for i in $(seq 0 $((ZONAL_DISK_COUNT - 1))); do
    cat >> resources.yaml <<YAML
  - metadata:
      name: ${DEVICE_PREFIX}-$i
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: ${STORAGE_CLASS}
      volumeMode: Block
      resources:
        requests:
          storage: ${ZONAL_DISK_SIZE}
YAML
  done

  cat >> resources.yaml <<YAML

#, Headless Service for zonal targets DNS
---
apiVersion: v1
kind: Service
metadata:
  name: zonal-service
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sanim
    app.kubernetes.io/component: target
    sanim.io/type: zonal
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: sanim
    app.kubernetes.io/component: target
    sanim.io/type: zonal
  ports:
  - name: iscsi
    port: 3260
    targetPort: 3260

YAML
fi

# Generate DaemonSet for initiators
cat >> resources.yaml <<YAML
#, DaemonSet for iSCSI initiators (dumb controller)
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: initiator
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: sanim
    app.kubernetes.io/component: initiator
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: sanim
      app.kubernetes.io/component: initiator
  template:
    metadata:
      labels:
        app.kubernetes.io/name: sanim
        app.kubernetes.io/component: initiator
    spec:
      serviceAccountName: default
      automountServiceAccountToken: false
      hostNetwork: true
      hostPID: true
YAML

# Add nodeSelector if NODE_LABEL_FILTER is set
if [ -n "$NODE_LABEL_FILTER" ]; then
  LABEL_KEY="${NODE_LABEL_FILTER%%=*}"
  LABEL_VALUE="${NODE_LABEL_FILTER#*=}"
  cat >> resources.yaml <<YAML
      nodeSelector:
        ${LABEL_KEY}: "${LABEL_VALUE}"
YAML
fi

cat >> resources.yaml <<YAML
      containers:
      - name: initiator
        image: ${IMAGE}
        command: ["/bin/bash", "/scripts/ds-init.sh"]
        env:
        - name: NAMESPACE
          value: "${NAMESPACE}"
        - name: IQN_PREFIX
          value: "${IQN_PREFIX}"
        - name: INSTALL_GLOBAL
          value: "${INSTALL_GLOBAL}"
        - name: INSTALL_ZONAL
          value: "${INSTALL_ZONAL}"
        - name: FORCE_CLEANUP
          value: "${FORCE_CLEANUP}"
        - name: NODE_ZONE
          valueFrom:
            fieldRef:
              fieldPath: metadata.labels['topology.kubernetes.io/zone']
        securityContext:
          privileged: true
        volumeMounts:
        - name: scripts
          mountPath: /scripts
        - name: dev
          mountPath: /dev
          mountPropagation: Bidirectional
        - name: iscsi-config
          mountPath: /etc/iscsi
          mountPropagation: Bidirectional
        - name: iscsi-lib
          mountPath: /var/lib/iscsi
          mountPropagation: Bidirectional
      volumes:
      - name: scripts
        configMap:
          name: scripts
          defaultMode: 0755
      - name: dev
        hostPath:
          path: /dev
      - name: iscsi-config
        hostPath:
          path: /etc/iscsi
      - name: iscsi-lib
        hostPath:
          path: /var/lib/iscsi
YAML

echo "Generated resources.yaml successfully!"
echo "Deploy with: oc apply -f resources.yaml"
