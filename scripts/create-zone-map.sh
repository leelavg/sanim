#!/bin/bash
set -euo pipefail

# Creates a ConfigMap with node-to-zone mapping for pods to lookup their zone
# Run this before deploying: bash scripts/create-zone-map.sh

NAMESPACE="${NAMESPACE:-sanim-system}"

echo "Creating node-to-zone mapping ConfigMap in namespace ${NAMESPACE}..."

# Build the mapping data
MAPPING=""
while IFS= read -r line; do
  NODE=$(echo "$line" | awk '{print $1}')
  ZONE=$(echo "$line" | awk '{print $2}')
  IP=$(oc get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  [ -n "$IP" ] && MAPPING+="    ${IP}=${ZONE}"$'\n'
done < <(oc get nodes -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone --no-headers)

if [ -z "$MAPPING" ]; then
  echo "Error: No nodes with zone labels found"
  exit 1
fi

# Apply ConfigMap directly
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-zone-map
  namespace: ${NAMESPACE}
data:
  mapping: |
${MAPPING}
EOF

echo "ConfigMap created successfully!"
echo "Mapping:"
echo "$MAPPING"
