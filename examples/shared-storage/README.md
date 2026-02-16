Shared Storage Example - Multiple pods access same global iSCSI LUN

This demonstrates the global target pattern where any pod from any zone can access the same storage.

Steps:
1. Deploy reader: kubectl apply -f shared-reader.yaml
2. Check logs: kubectl logs -n sanim-system shared-reader
3. Verify: Pod formats (if needed) and reads data from global LUN

Use case: Shared content (static websites, shared uploads, read-heavy workloads)

Note: Init container formats on first run (idempotent), main container mounts read-only
