# Shared Storage Example

This example demonstrates shared storage using the global iSCSI target.

## What it tests

- Multiple nodes accessing the **same** global LUN
- Data written from node A is visible on node B
- Raw block-level I/O across nodes

## How it works

1. **Writer pod**: Runs on any node, writes magic marker + data to global device
2. **Reader pod**: Runs on a **different** node (via podAntiAffinity), polls for marker, then reads data

Synchronization via magic marker pattern at block 0.

## Usage

```bash
# Deploy writer first
oc apply -f writer.yaml

# Wait for writer to write data (check logs)
oc logs -n sanim-system shared-writer

# Deploy reader (will run on different node)
oc apply -f reader.yaml

# Check reader logs - should show data from writer
oc logs -n sanim-system shared-reader -f
```

## Cleanup

```bash
oc delete -f reader.yaml
oc delete -f writer.yaml
```

## Expected output

Reader should show:
```
Data read: Shared storage written at 2026-02-17T... from <writer-node>
Proof of shared storage: data written from writer node visible on reader node
```
