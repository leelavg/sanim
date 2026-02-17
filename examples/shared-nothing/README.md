# Shared-Nothing (Zonal) Storage Example

This example demonstrates zone-isolated storage using zonal iSCSI targets.

## What it tests

- **Zone-specific storage** - each zone has its own target
- **All nodes in a zone** can access that zone's zonal storage
- **Storage is isolated per zone** (shared-nothing architecture)

## How it works

- DaemonSet runs on all worker nodes
- Each node accesses its zone's target (e.g., `iqn.2020-05.com.thoughtexpo:storage:us-east-1d`)
- Multiple nodes in same zone share the zonal device
- Each node writes to different offset to avoid conflicts

## Usage

```bash
# Deploy zonal test DaemonSet
oc apply -f zonal-test.yaml

# Check pods (one per node)
oc get pods -n sanim-system -l app=zonal-storage-test -o wide

# Check logs from all pods
oc logs -n sanim-system -l app=zonal-storage-test --tail=20 --prefix
```

## Cleanup

```bash
oc delete -f zonal-test.yaml
```

## Expected output

Each pod should show:
```
Running on node in zone: us-east-1d
Found device: /dev/sdX for zone: us-east-1d
Writing to block offset: <offset>
Read from offset <offset>: Zone: us-east-1d | Node: <node-name> | ...
Device /dev/sdX is shared among all nodes in zone: us-east-1d
```

## Zone isolation

With multiple zones:
- Zone A: `iqn.2020-05.com.thoughtexpo:storage:us-east-1a` → separate LUN
- Zone B: `iqn.2020-05.com.thoughtexpo:storage:us-east-1b` → separate LUN
- Pods in zone A cannot access zone B's storage (zone-isolated)
