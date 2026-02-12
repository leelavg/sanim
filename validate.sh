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

# Check if namespace exists
echo -n "Checking namespace ${NAMESPACE}... "
if oc get namespace "${NAMESPACE}" &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Namespace not found${NC}"
    exit 1
fi

# Check ConfigMap
echo -n "Checking ConfigMap... "
if oc get configmap scripts -n "${NAMESPACE}" &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ ConfigMap not found${NC}"
    exit 1
fi

# Check SCC
echo -n "Checking SecurityContextConstraints... "
if oc get scc sanim-privileged &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ SCC not found${NC}"
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
            echo "  Target details:"
            oc exec -n "${NAMESPACE}" "$POD" -- targetcli /iscsi ls 2>/dev/null | sed 's/^/    /'
        else
            echo -e "${RED}✗${NC}"
        fi
    fi
fi

# Check Zonal STS if enabled
if [ "$INSTALL_ZONAL" == "true" ]; then
    echo ""
    echo "Zonal Targets Validation:"
    echo "-------------------------"
    
    echo -n "  StatefulSet... "
    if oc get sts zonal -n "${NAMESPACE}" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗ Not found${NC}"
        exit 1
    fi
    
    echo -n "  Service... "
    if oc get svc zonal-service -n "${NAMESPACE}" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗ Not found${NC}"
        exit 1
    fi
    
    echo -n "  Pods ready... "
    READY=$(oc get sts zonal -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(oc get sts zonal -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [ "$READY" == "$DESIRED" ] && [ "$DESIRED" -gt "0" ]; then
        echo -e "${GREEN}✓ (${READY}/${DESIRED})${NC}"
    else
        echo -e "${YELLOW}⚠ (${READY}/${DESIRED})${NC}"
    fi
    
    echo -n "  PVCs bound... "
    BOUND=$(oc get pvc -n "${NAMESPACE}" -l app.kubernetes.io/component=target,sanim.io/type=zonal --no-headers 2>/dev/null | grep -c "Bound" || echo "0")
    TOTAL=$(oc get pvc -n "${NAMESPACE}" -l app.kubernetes.io/component=target,sanim.io/type=zonal --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$BOUND" == "$TOTAL" ] && [ "$TOTAL" -gt "0" ]; then
        echo -e "${GREEN}✓ (${BOUND}/${TOTAL})${NC}"
    else
        echo -e "${YELLOW}⚠ (${BOUND}/${TOTAL})${NC}"
    fi
    
    # Check each zonal target
    PODS=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=target,sanim.io/type=zonal --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
    if [ -n "$PODS" ]; then
        echo "  Zonal target details:"
        while IFS= read -r POD; do
            ZONE=$(oc get pod "$POD" -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "unknown")
            echo -n "    ${POD} (${ZONE})... "
            if oc exec -n "${NAMESPACE}" "$POD" -- targetcli /iscsi ls 2>/dev/null | grep -q "iqn"; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${RED}✗${NC}"
            fi
        done <<< "$PODS"
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

# Check iSCSI sessions on initiators (kernel-level verification)
INIT_PODS=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=initiator --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -3)
if [ -n "$INIT_PODS" ]; then
    echo "  Kernel iSCSI sessions (sample):"
    COUNT=0
    SESSION_COUNT=0
    while IFS= read -r POD && [ $COUNT -lt 3 ]; do
        NODE=$(oc get pod "$POD" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")
        echo "    ${POD} (${NODE}):"
        
        # Verify kernel sessions exist
        SESSIONS=$(oc exec -n "${NAMESPACE}" "$POD" -- iscsiadm --mode session 2>/dev/null)
        if [ -z "$SESSIONS" ]; then
            echo -e "      ${YELLOW}⚠ No active kernel sessions${NC}"
        else
            echo "$SESSIONS" | sed 's/^/      /'
            SESSION_COUNT=$((SESSION_COUNT + 1))
            
            # Verify block devices are visible
            echo "      Block devices:"
            oc exec -n "${NAMESPACE}" "$POD" -- lsblk -d -o NAME,SIZE,TYPE 2>/dev/null | grep disk | sed 's/^/        /' || echo -e "        ${YELLOW}⚠ No block devices found${NC}"
        fi
        COUNT=$((COUNT + 1))
    done <<< "$INIT_PODS"
    
    if [ $SESSION_COUNT -eq 0 ]; then
        echo -e "  ${RED}✗ No kernel sessions found on any initiator${NC}"
    fi
fi

# Summary
echo ""
echo "=========================================="
echo "Validation Summary"
echo "=========================================="

TOTAL_CHECKS=0
PASSED_CHECKS=0

# Count checks
if [ "$INSTALL_GLOBAL" == "true" ]; then
    TOTAL_CHECKS=$((TOTAL_CHECKS + 4))
    READY=$(oc get sts global -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    [ "$READY" == "1" ] && PASSED_CHECKS=$((PASSED_CHECKS + 1))
fi

if [ "$INSTALL_ZONAL" == "true" ]; then
    TOTAL_CHECKS=$((TOTAL_CHECKS + 4))
    READY=$(oc get sts zonal -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(oc get sts zonal -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    [ "$READY" == "$DESIRED" ] && [ "$DESIRED" -gt "0" ] && PASSED_CHECKS=$((PASSED_CHECKS + 1))
fi

TOTAL_CHECKS=$((TOTAL_CHECKS + 2))
READY=$(oc get ds initiator -n "${NAMESPACE}" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
DESIRED=$(oc get ds initiator -n "${NAMESPACE}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
[ "$READY" == "$DESIRED" ] && [ "$DESIRED" -gt "0" ] && PASSED_CHECKS=$((PASSED_CHECKS + 1))

if [ $PASSED_CHECKS -eq $TOTAL_CHECKS ]; then
    echo -e "${GREEN}All checks passed!${NC}"
    echo ""
    echo "Next steps:"
    echo "  - Check block devices on worker nodes: lsblk"
    echo "  - Verify iSCSI sessions: iscsiadm -m session"
    echo "  - Test I/O: dd if=/dev/zero of=/dev/sdX bs=1M count=100"
else
    echo -e "${YELLOW}Some checks need attention (${PASSED_CHECKS}/${TOTAL_CHECKS} passed)${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check pod logs: oc logs -n ${NAMESPACE} <pod-name>"
    echo "  - Verify PVC status: oc get pvc -n ${NAMESPACE}"
    echo "  - Check events: oc get events -n ${NAMESPACE} --sort-by='.lastTimestamp'"
fi

echo ""
