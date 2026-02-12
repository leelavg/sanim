# sanim - SAN Simulator

**sanim** (SAN Simulator) is a zero-dependency Bash generator that provides iSCSI block storage on AWS/OpenShift clusters using Fedora 43 containers.

## Overview

sanim enables you to quickly provision iSCSI block storage within your Kubernetes/OpenShift cluster for testing, development, or ephemeral workloads. It uses StatefulSets as iSCSI targets and a DaemonSet as a "dumb" initiator controller.

## Architecture

### Components

1. **STS-Global (Optional)**: A single-replica StatefulSet that exports LUNs cluster-wide from a specific availability zone
2. **STS-Zonal (Optional)**: A multi-replica StatefulSet (one per zone) that exports zone-local LUNs with shared-nothing architecture
3. **DS-Initiator**: A DaemonSet that performs iSCSI login and maintains sessions, letting the host kernel handle the data path
4. **ConfigMap**: Contains entrypoint scripts for all components
5. **SCC**: Custom SecurityContextConstraints for privileged operations

### Flow

```
User → config.env → generate.sh → resources.yaml → oc apply
                                                      ↓
                                    ┌─────────────────┴─────────────────┐
                                    ↓                                   ↓
                            STS (iSCSI Target)              DS (iSCSI Initiator)
                            - Creates LUNs                  - Discovers targets
                            - Exports via targetcli         - Performs login
                            - Stable DNS via Service        - Maintains sessions
                                                            - Host kernel handles I/O
```

## FAQ

### Why StatefulSets for targets?

StatefulSets provide:
- **Stable DNS names**: Each pod gets a predictable hostname (e.g., `global-0.global-service`)
- **Sticky PVCs**: Volumes remain bound to specific pods across restarts
- **Zone affinity**: Combined with `WaitForFirstConsumer`, ensures PVCs stay in the correct availability zone

### Why is the DaemonSet "dumb"?

The initiator DaemonSet is intentionally simple:
- It only performs `iscsiadm` login operations
- It does NOT start `iscsid` in the container
- The host kernel manages the actual iSCSI sessions and data path
- **Critical benefit**: If the DS pod restarts, iSCSI sessions remain active, preventing I/O disruption

### How does the host-container flow work?

**Target (STS)**:
- Container runs `targetcli` to configure iSCSI targets
- `/dev` is mounted with `HostToContainer` propagation
- Block devices from PVCs are visible and exported

**Initiator (DS)**:
- Container talks to host's iSCSI stack via bidirectional mounts:
  - `/etc/iscsi` (configuration)
  - `/var/lib/iscsi` (session state)
  - `/dev` (block devices)
- `iscsiadm` commands affect the **host kernel**, not the container
- Sessions persist even if the container restarts

### Why avoid starting iscsid in containers?

Starting `iscsid` in containers would:
- Create session state inside the container (lost on restart)
- Conflict with the host's iSCSI daemon
- Break the "dumb controller" pattern
- Cause I/O hangs during pod restarts

## Usage

### 1. Survey Your Cluster

Identify node labels and availability zones:

```bash
oc get nodes --show-labels
```

Look for `topology.kubernetes.io/zone` labels (e.g., `us-east-1a`, `us-east-1b`, `us-east-1c`).

### 2. Configure

Create or edit `config.env`:

```bash
cp config.env.example config.env
```

Example configuration:

```bash
NAMESPACE=sanim-system
INSTALL_GLOBAL=true
INSTALL_ZONAL=true
GLOBAL_LUN_COUNT=2
GLOBAL_LUN_SIZE=10Gi
GLOBAL_ZONE=us-east-1a
ZONAL_LUN_COUNT=1
ZONAL_LUN_SIZE=10Gi
IQN_PREFIX=iqn.2026-02.local.sanim
STORAGE_CLASS=gp3-csi
DEVICE_PREFIX=sanim
IMAGE=quay.io/sanim/engine:latest
NODE_LABEL_FILTER=node-role.kubernetes.io/worker=
```

### 3. Generate Resources

```bash
bash generate.sh
```

This creates `resources.yaml` with all necessary Kubernetes resources.

### 4. Deploy

```bash
oc apply -f resources.yaml
```

### 5. Verify

Check that all components are running:

```bash
# Check targets
oc get sts -n sanim-system
oc get pods -n sanim-system -l app.kubernetes.io/component=target

# Check initiators
oc get ds -n sanim-system
oc get pods -n sanim-system -l app.kubernetes.io/component=initiator

# Verify iSCSI sessions (from any initiator pod)
oc exec -n sanim-system <initiator-pod> -- iscsiadm --mode session
```

### 6. Inspect Resources

List all generated resources:

```bash
grep '^#,' resources.yaml
```

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `sanim-system` | Namespace for all resources |
| `INSTALL_GLOBAL` | `false` | Enable global shared target |
| `INSTALL_ZONAL` | `false` | Enable zonal shared-nothing targets |
| `GLOBAL_LUN_COUNT` | `2` | Number of LUNs for global target |
| `GLOBAL_LUN_SIZE` | `10Gi` | Size of each global LUN |
| `GLOBAL_ZONE` | - | Zone for global target (required if `INSTALL_GLOBAL=true`) |
| `ZONAL_LUN_COUNT` | `1` | Number of LUNs per zonal target |
| `ZONAL_LUN_SIZE` | `10Gi` | Size of each zonal LUN |
| `IQN_PREFIX` | `iqn.2026-02.local.sanim` | iSCSI Qualified Name prefix |
| `STORAGE_CLASS` | `gp3-csi` | StorageClass for PVCs |
| `DEVICE_PREFIX` | `sanim` | Prefix for block device names |
| `IMAGE` | `quay.io/sanim/engine:latest` | Container image |
| `NODE_LABEL_FILTER` | `node-role.kubernetes.io/worker=` | Node selector for initiators |
| `FORCE_CLEANUP` | `false` | Logout sessions on pod termination |

## Building the Container Image

```bash
podman build -t quay.io/sanim/engine:latest -f Containerfile .
podman push quay.io/sanim/engine:latest
```

## iSCSI Concepts

### IQN (iSCSI Qualified Name)

Format: `iqn.YYYY-MM.reverse.domain:identifier`

sanim uses:
- Global: `iqn.2026-02.local.sanim:global`
- Zonal: `iqn.2026-02.local.sanim:zone-<zone-name>`

### Target vs Initiator

- **Target**: The server that exports storage (STS pods)
- **Initiator**: The client that consumes storage (DS pods)

### Discovery and Login

1. **Discovery**: Find available targets
   ```bash
   iscsiadm --mode discovery --type sendtargets --portal <DNS>
   ```

2. **Login**: Establish a session
   ```bash
   iscsiadm --mode node --targetname <IQN> --portal <DNS> --login
   ```

3. **Session**: Active connection between initiator and target
   ```bash
   iscsiadm --mode session
   ```

## Troubleshooting

### No LUNs found in target pod

Check that PVCs are bound:
```bash
oc get pvc -n sanim-system
```

Verify block devices are visible:
```bash
oc exec -n sanim-system <target-pod> -- ls -la /dev/sanim-*
```

### Initiator cannot discover targets

Check service DNS resolution:
```bash
oc exec -n sanim-system <initiator-pod> -- getent hosts global-service.sanim-system.svc.cluster.local
```

Verify target is listening:
```bash
oc exec -n sanim-system <target-pod> -- targetcli /iscsi ls
```

### Sessions not persisting

Ensure `FORCE_CLEANUP=false` in config.env. Sessions should survive pod restarts because they're managed by the host kernel.

### Kernel-level iSCSI troubleshooting

iSCSI login failures, CHAP mismatches, or session errors are often only visible in the host kernel logs. To view them:

**From initiator pod (if /dev/kmsg is accessible):**
```bash
oc exec -n sanim-system <initiator-pod> -- cat /dev/kmsg | grep -i iscsi
```

**From the host node directly:**
```bash
oc debug node/<node-name>
chroot /host
dmesg | grep -i iscsi
journalctl -k | grep -i iscsi
```

Common kernel messages to look for:
- `connection1:0: detected conn error` - Network/portal issues
- `session recovery timed out` - Target unreachable
- `Login failed` - Authentication or target configuration issues

### Zone mismatch for zonal targets

Verify pod zone labels:
```bash
oc get pods -n sanim-system -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.'topology\.kubernetes\.io/zone'
```

## Security Considerations

- sanim requires privileged containers and host access
- Use only in trusted environments (dev/test clusters)
- Not recommended for production workloads
- No CHAP authentication configured by default

## Multipath Configuration

On OpenShift/RHCOS nodes with multipathd active, you must blacklist sanim devices to prevent the host from managing them:

Add to /etc/multipath.conf on all worker nodes:
```
blacklist {
    wwid ".*"
    devnode "^sd[a-z]+"
}
blacklist_exceptions {
    property "(SCSI_IDENT_|ID_WWN)"
}
blacklist {
    device {
        vendor "LIO-ORG"
        product ".*"
    }
}
```

Or specifically blacklist by IQN pattern:
```
blacklist {
    wwid "iqn.2026-02.com.thoughtexpo:storage.*"
}
```

After updating, reload multipathd:
```bash
systemctl reload multipathd
```

## Cleanup

```bash
oc delete -f resources.yaml
```

**Note**: PVCs are retained by default. To delete them:

```bash
oc delete pvc -n sanim-system --all
```

## Requirements

- OpenShift 4.x or Kubernetes 1.20+
- StorageClass with `WaitForFirstConsumer` binding mode
- **StorageClass MUST support `volumeMode: Block`** (raw block volumes)
- Nodes with `topology.kubernetes.io/zone` labels
- Cluster admin privileges (for SCC creation)

**Important**: Verify your StorageClass supports block volumes:
```bash
oc get storageclass <your-class> -o yaml | grep volumeBindingMode
# Should show: volumeBindingMode: WaitForFirstConsumer
```

If your StorageClass doesn't support block mode, sanim PVCs will fail to bind.

## License

MIT

## Contributing

Contributions welcome! Please ensure:
- Scripts remain zero-dependency (pure Bash)
- Follow existing patterns for heredocs and indentation
- Test with both global and zonal configurations
- Update documentation for new features
