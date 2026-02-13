#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Source config if exists
[ -f config.env ] && source config.env

NAMESPACE="${NAMESPACE:-sanim-system}"
INSTALL_GLOBAL="${INSTALL_GLOBAL:-false}"
INSTALL_ZONAL="${INSTALL_ZONAL:-false}"

echo "=========================================="
echo "sanim Validation Script"
echo "=========================================="
echo ""

# Check zones.txt
echo -n "Checking zones.txt... "
if [ -f "zones.txt" ]; then
    ZONES=($(cat zones.txt))
    echo -e "${GREEN}✓ (${#ZONES[@]} zones: ${ZONES[@]})${NC}"
else
    echo -e "${YELLOW}⚠ Not found (run: bash generate.sh -m)${NC}"
fi

# Check namespace
echo -n "Checking namespace ${NAMESPACE}... "
if oc get namespace "${NAMESPACE}" &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not found${NC}"
    exit 1
fi

# Check ConfigMaps
echo -n "Checking ConfigMap scripts... "
if oc get configmap scripts -n "${NAMESPACE}" &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not found${NC}"
    exit 1
fi

echo -n "Checking ConfigMap node-zone-map... "
if oc get configmap node-zone-map -n "${NAMESPACE}" &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${YELLOW}⚠ Not found (run: bash generate.sh -m)${NC}"
fi

# Check SCCs
echo -n "Checking SCC sanim-target... "
if oc get scc sanim-target &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not found${NC}"
    exit 1
fi

echo -n "Checking SCC sanim-initiator... "
if oc get scc sanim-initiator &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not found${NC}"
    exit 1
fi

# Check Global STS if enabled
if [ "$INSTALL_GLOBAL" == "true" ]; then
    echo ""
    echo "Global Target Validation:"
    echo "-------------------------"
    
    echo -n "  StatefulSet... "
    if oc get sts global -n "${NAMESPACE}" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗ Not found${NC}"
        exit 1
    fi
    
    echo -n "  Service... "
    if oc get svc global-service -n "${NAMESPACE}" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗ Not found${NC}"
        exit 1
    fi
    
    echo -n "  Pod ready... "
    READY=$(oc get sts global -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "$READY" == "1" ]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}⚠ Not ready (${READY}/1)${NC}"
    fi
    
    echo -n "  PVCs bound... "
    BOUND=$(oc get pvc -n "${NAMESPACE}" -l app.kubernetes.io/component=target,sanim.io/type=global --no-headers 2>/dev/null | grep -c "Bound" || echo "0")
    TOTAL=$(oc get pvc -n "${NAMESPACE}" -l app.kubernetes.io/component=target,sanim.io/type=global --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$BOUND" == "$TOTAL" ] && [ "$TOTAL" -gt "0" ]; then
        echo -e "${GREEN}✓ (${BOUND}/${TOTAL})${NC}"
    else
        echo -e "${YELLOW}⚠ (${BOUND}/${TOTAL})${NC}"
    fi
    
    # Check target configuration
    POD=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=target,sanim.io/type=global --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
    if [ -n "$POD" ]; then
        echo -n "  iSCSI target configured... "
        if oc exec -n "${NAMESPACE}" "$POD" -- targetcli /iscsi ls 2>/dev/null | grep -q "iqn"; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
        fi

        echo -n "  Port 3260 listening... "
        if oc exec -n "${NAMESPACE}" "$POD" -- ss -tlnp 2>/dev/null | grep -q ":3260"; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
        fi

        echo "  Target details:"
        oc exec -n "${NAMESPACE}" "$POD" -- targetcli /iscsi ls 2>/dev/null | sed 's/^/    /'
    fi
fi

# Check Zonal STS if enabled
if [ "$INSTALL_ZONAL" == "true" ]; then
    echo ""
    echo "Zonal Targets Validation:"
    echo "-------------------------"

    # Get all zonal StatefulSets
    ZONAL_STS=$(oc get sts -n "${NAMESPACE}" -l sanim.io/type=zonal --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
    if [ -z "$ZONAL_STS" ]; then
        echo -e "  ${RED}✗ No zonal StatefulSets found${NC}"
    else
        ZONE_COUNT=$(echo "$ZONAL_STS" | wc -l)
        echo "  Found ${ZONE_COUNT} zonal StatefulSet(s)"

        while IFS= read -r STS; do
            ZONE=$(oc get sts "$STS" -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.sanim\.io/zone}' 2>/dev/null)
            echo ""
            echo "  Zone: ${ZONE} (${STS})"

            # Check Service
            SVC_NAME="${STS}-service"
            echo -n "    Service... "
            if oc get svc "$SVC_NAME" -n "${NAMESPACE}" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${RED}✗ Not found${NC}"
            fi

            # Check Pod ready
            echo -n "    Pod ready... "
            READY=$(oc get sts "$STS" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            if [ "$READY" == "1" ]; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${YELLOW}⚠ Not ready${NC}"
            fi

            # Check PVCs
            echo -n "    PVCs bound... "
            BOUND=$(oc get pvc -n "${NAMESPACE}" -l sanim.io/zone="${ZONE}" --no-headers 2>/dev/null | grep -c "Bound" || echo "0")
            TOTAL=$(oc get pvc -n "${NAMESPACE}" -l sanim.io/zone="${ZONE}" --no-headers 2>/dev/null | wc -l || echo "0")
            if [ "$BOUND" == "$TOTAL" ] && [ "$TOTAL" -gt "0" ]; then
                echo -e "${GREEN}✓ (${BOUND}/${TOTAL})${NC}"
            else
                echo -e "${YELLOW}⚠ (${BOUND}/${TOTAL})${NC}"
            fi

            # Check target configuration
            POD=$(oc get pods -n "${NAMESPACE}" -l sanim.io/zone="${ZONE}",app.kubernetes.io/component=target --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
            if [ -n "$POD" ]; then
                echo -n "    iSCSI target... "
                if oc exec -n "${NAMESPACE}" "$POD" -- targetcli /iscsi ls 2>/dev/null | grep -q "iqn"; then
                    echo -e "${GREEN}✓${NC}"
                else
                    echo -e "${RED}✗${NC}"
                fi

                echo -n "    Port 3261 listening... "
                if oc exec -n "${NAMESPACE}" "$POD" -- ss -tlnp 2>/dev/null | grep -q ":3261"; then
                    echo -e "${GREEN}✓${NC}"
                else
                    echo -e "${RED}✗${NC}"
                fi
            fi
        done <<< "$ZONAL_STS"
    fi
fi

# Check DaemonSet
echo ""
echo "Initiator Validation:"
echo "---------------------"

echo -n "  DaemonSet... "
if oc get ds initiator -n "${NAMESPACE}" &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not found${NC}"
    exit 1
fi

echo -n "  Pods ready... "
READY=$(oc get ds initiator -n "${NAMESPACE}" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
DESIRED=$(oc get ds initiator -n "${NAMESPACE}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
if [ "$READY" == "$DESIRED" ] && [ "$DESIRED" -gt "0" ]; then
    echo -e "${GREEN}✓ (${READY}/${DESIRED})${NC}"
else
    echo -e "${YELLOW}⚠ (${READY}/${DESIRED})${NC}"
fi

# Check iSCSI sessions on initiators (kernel-level verification via nsenter)
INIT_PODS=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=initiator --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -3)
if [ -n "$INIT_PODS" ]; then
    echo "  Kernel iSCSI sessions (via nsenter, sample 3 nodes):"
    COUNT=0
    SESSION_COUNT=0
    while IFS= read -r POD && [ $COUNT -lt 3 ]; do
        NODE=$(oc get pod "$POD" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")
        ZONE=$(oc get pod "$POD" -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "unknown")
        echo "    ${POD} (${NODE}, ${ZONE}):"

        # Verify kernel sessions using nsenter (same pattern as ds-init.sh)
        SESSIONS=$(oc exec -n "${NAMESPACE}" "$POD" -- nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm --mode session 2>/dev/null)
        if [ -z "$SESSIONS" ]; then
            echo -e "      ${YELLOW}⚠ No active kernel sessions${NC}"
        else
            echo "$SESSIONS" | sed 's/^/      /'
            SESSION_COUNT=$((SESSION_COUNT + 1))

            # Check sysfs session health
            echo "      Session health (sysfs):"
            HEALTH=$(oc exec -n "${NAMESPACE}" "$POD" -- nsenter -t 1 -m bash -c "ls -d /sys/class/iscsi_session/session* 2>/dev/null | while read s; do echo \"\$(basename \$s): \$(cat \$s/state 2>/dev/null)\"; done" 2>/dev/null)
            if [ -n "$HEALTH" ]; then
                echo "$HEALTH" | sed 's/^/        /'
            fi
        fi
        COUNT=$((COUNT + 1))
    done <<< "$INIT_PODS"

    if [ $SESSION_COUNT -eq 0 ]; then
        echo -e "  ${RED}✗ No kernel sessions found on any initiator${NC}"
    else
        echo -e "  ${GREEN}✓ Found active sessions on ${SESSION_COUNT} node(s)${NC}"
    fi
fi

# Summary
echo ""
echo "=========================================="
echo "Validation Summary"
echo "=========================================="

# Component status
if [ "$INSTALL_GLOBAL" == "true" ]; then
    GLOBAL_READY=$(oc get sts global -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    echo -n "Global target: "
    if [ "$GLOBAL_READY" == "1" ]; then
        echo -e "${GREEN}✓ Ready${NC}"
    else
        echo -e "${YELLOW}⚠ Not ready${NC}"
    fi
fi

if [ "$INSTALL_ZONAL" == "true" ]; then
    ZONAL_STS=$(oc get sts -n "${NAMESPACE}" -l sanim.io/type=zonal --no-headers 2>/dev/null | wc -l)
    ZONAL_READY=$(oc get sts -n "${NAMESPACE}" -l sanim.io/type=zonal -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | grep -c "^1$" || echo "0")
    echo -n "Zonal targets: "
    if [ "$ZONAL_READY" == "$ZONAL_STS" ] && [ "$ZONAL_STS" -gt "0" ]; then
        echo -e "${GREEN}✓ ${ZONAL_READY}/${ZONAL_STS} zones ready${NC}"
    else
        echo -e "${YELLOW}⚠ ${ZONAL_READY}/${ZONAL_STS} zones ready${NC}"
    fi
fi

DS_READY=$(oc get ds initiator -n "${NAMESPACE}" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
DS_DESIRED=$(oc get ds initiator -n "${NAMESPACE}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
echo -n "Initiators: "
if [ "$DS_READY" == "$DS_DESIRED" ] && [ "$DS_DESIRED" -gt "0" ]; then
    echo -e "${GREEN}✓ ${DS_READY}/${DS_DESIRED} nodes${NC}"
else
    echo -e "${YELLOW}⚠ ${DS_READY}/${DS_DESIRED} nodes${NC}"
fi

echo ""
echo "Next steps:"
echo "  - View sessions on node: oc exec -n ${NAMESPACE} <initiator-pod> -- nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm -m session"
echo "  - Check kernel logs: oc debug node/<node> → chroot /host → dmesg | grep -i iscsi"
echo "  - List block devices: lsblk | grep -E 'sd[b-z]'"
echo "  - Test I/O: dd if=/dev/zero of=/dev/sdX bs=1M count=100 oflag=direct"
echo ""
