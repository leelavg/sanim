# sanim - SAN Simulator

**sanim** (SAN Simulator) is a zero-dependency Bash generator that provides iSCSI block storage on AWS/OpenShift clusters using Fedora 43 containers. Battle-tested through live cluster deployment with comprehensive fixes applied.

## Overview

sanim enables you to quickly provision iSCSI block storage within your Kubernetes/OpenShift cluster for testing, development, or ephemeral workloads. It uses StatefulSets as iSCSI targets and a DaemonSet as a "dumb" initiator controller.

## Architecture

### Components

1. **STS-Global (Optional)**: A single-replica StatefulSet that exports LUNs cluster-wide from a specific availability zone
2. **STS-Zonal (Optional)**: A multi-replica StatefulSet (one per zone) that exports zone-local LUNs with shared-nothing architecture
3. **DS-Initiator**: A DaemonSet that performs iSCSI login and maintains sessions, letting the host kernel handle the data path
4. **ConfigMap**: Contains entrypoint scripts (externalized in `scripts/` directory for IDE syntax highlighting)
5. **SCC**: Custom SecurityContextConstraints for privileged operations

### Flow

```
User → config.env → generate.sh → resources.yaml → oc apply
                                                      ↓
                                    ┌─────────────────┴─────────────────┐
                                    ↓                                   ↓
                            STS (iSCSI Target)              DS (iSCSI Initiator)
                            - Creates LUNs                  - Discovers targets (via nsenter)
                            - Exports via targetcli         - Performs login (host iscsiadm)
                            - Stable DNS via Service        - Maintains sessions
                                                            - Host kernel handles I/O
```

## Live Testing Insights

sanim has been deployed and tested on a live OpenShift cluster. Key fixes applied:

### Critical Fixes
- **volumeDevices vs /dev mount**: Removed `/dev` hostPath mount from targets (conflicted with volumeDevices)
- **DNS resolution**: Changed to `dnsPolicy: ClusterFirstWithHostNet` for hostNetwork pods
- **iscsiadm compatibility**: Use `nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm` to run host's iscsiadm (Fedora 43 version incompatible with RHCOS kernel)
- **Target mounts**: Added `/var/run/dbus` (ro) for targetcli and `/sys/kernel/config` for configfs
- **Termination log path**: Set to `/tmp/termination-log` to avoid `/dev` conflicts

### Semantic Improvements
- **IQN format**: Hardcoded to `iqn.2020-05.com.thoughtexpo:storage` (reflects domain registration date)
- **Zonal IQN**: Simplified to `iqn.2020-05.com.thoughtexpo:storage:us-west-1a` (removed redundant "zone-" prefix)
- **Device prefixes**: Hardcoded to `global-*` and `zonal-*` (self-documenting, not configurable)

### Code Quality
- **Externalized scripts**: Scripts moved to `scripts/` directory for full IDE syntax highlighting
- **Orphaned cleanup**: Added to zonal script (matches global robustness)
- **Login warnings**: Clear visibility when iSCSI connections fail
- **Mount optimization**: Changed to `HostToContainer` propagation (initiator uses nsenter)
- **Removed unnecessary mounts**: `/var/run/dbus` and `/sys` from initiator (not needed with nsenter)

## FAQ

### Why StatefulSets for targets?

StatefulSets provide:
- **Stable DNS names**: Each pod gets a predictable hostname (e.g., `global-0.global-service`)
- **Sticky PVCs**: Volumes remain bound to specific pods across restarts
- **Zone affinity**: Combined with `WaitForFirstConsumer`, ensures PVCs stay in the correct availability zone

### Why is the DaemonSet "dumb"?

The initiator DaemonSet is intentionally simple:
- It only performs `iscsiadm` login operations via `nsenter` to the host
- It does NOT start `iscsid` in the container
- The host kernel manages the actual iSCSI sessions and data path
- **Critical benefit**: If the DS pod restarts, iSCSI sessions remain active, preventing I/O disruption

### How does the host-container flow work?

**Target (STS)**:
- Container runs `targetcli` to configure iSCSI targets
- Block devices from PVCs are exposed via `volumeDevices` (not hostPath mounts)
- `/var/run/dbus` mounted (ro) for targetcli communication
- `/sys/kernel/config` mounted for configfs access

**Initiator (DS)**:
- Container uses `nsenter` to run host's `iscsiadm` (compatibility fix)
- Mounts with `HostToContainer` propagation:
  - `/dev` (see block devices)
  - `/etc/iscsi` (configuration)
  - `/var/lib/iscsi` (session state)
- `iscsiadm` commands affect the **host kernel**, not the container
- Sessions persist even if the container restarts

### Why use nsenter for iscsiadm?

Fedora 43's iscsiadm (version 6.2.1.11) is incompatible with RHEL CoreOS kernel. Using `nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm` runs the host's iscsiadm, ensuring compatibility.

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
GLOBAL_DISK_COUNT=2
GLOBAL_DISK_SIZE=10Gi
GLOBAL_ZONE=us-east-1a
ZONAL_DISK_COUNT=1
ZONAL_DISK_SIZE=10Gi
STORAGE_CLASS=gp3-csi
IMAGE=ghcr.io/leelavg/sanim:latest
NODE_LABEL_FILTER=node-role.kubernetes.io/worker=
```

**Note**: IQN and device prefixes are now hardcoded:
- IQN: `iqn.2020-05.com.thoughtexpo:storage`
- Device prefixes: `global-*` for shared-storage, `zonal-*` for shared-nothing

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

# Verify iSCSI sessions (from any initiator pod using nsenter)
oc exec -n sanim-system <initiator-pod> -- nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm --mode session
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
| `GLOBAL_DISK_COUNT` | `2` | Number of LUNs for global target |
| `GLOBAL_DISK_SIZE` | `10Gi` | Size of each global LUN |
| `GLOBAL_ZONE` | - | Zone for global target (required if `INSTALL_GLOBAL=true`) |
| `ZONAL_DISK_COUNT` | `1` | Number of LUNs per zonal target |
| `ZONAL_DISK_SIZE` | `10Gi` | Size of each zonal LUN |
| `STORAGE_CLASS` | `gp3-csi` | StorageClass for PVCs |
| `IMAGE` | `ghcr.io/leelavg/sanim:latest` | Container image |
| `NODE_LABEL_FILTER` | `node-role.kubernetes.io/worker=` | Node selector for initiators |
| `FORCE_CLEANUP` | `false` | Logout sessions on pod termination |

**Hardcoded values** (not configurable):
- IQN prefix: `iqn.2020-05.com.thoughtexpo:storage`
- Device prefixes: `global` and `zonal`

## Building the Container Image

```bash
podman build -t ghcr.io/leelavg/sanim:latest -f Containerfile .
podman push ghcr.io/leelavg/sanim:latest
```

The container includes:
- `targetcli-fb` for iSCSI target configuration
- `util-linux` for nsenter
- Debug tools: `bind-utils`, `iputils`, `tcpdump`

## iSCSI Concepts

### IQN (iSCSI Qualified Name)

Format: `iqn.YYYY-MM.reverse.domain:identifier`

sanim uses:
- Global: `iqn.2020-05.com.thoughtexpo:storage:global`
- Zonal: `iqn.2020-05.com.thoughtexpo:storage:us-west-1a` (example)

### Target vs Initiator

- **Target**: The server that exports storage (STS pods)
- **Initiator**: The client that consumes storage (DS pods using host's iscsiadm)

### Discovery and Login

1. **Discovery**: Find available targets
   ```bash
   nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm --mode discovery --type sendtargets --portal <DNS>
   ```

2. **Login**: Establish a session
   ```bash
   nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm --mode node --targetname <IQN> --portal <DNS> --login
   ```

3. **Session**: Active connection between initiator and target
   ```bash
   nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm --mode session
   ```

## Troubleshooting

### No LUNs found in target pod

Check that PVCs are bound:
```bash
oc get pvc -n sanim-system
```

Verify block devices are visible via volumeDevices:
```bash
oc exec -n sanim-system <target-pod> -- ls -la /dev/global-* /dev/zonal-*
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

### iscsiadm version mismatch

If you see errors about incompatible iscsiadm versions, ensure the initiator is using `nsenter` to run the host's iscsiadm:
```bash
oc exec -n sanim-system <initiator-pod> -- nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm --version
```

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

### DNS resolution issues with hostNetwork

If initiators can't resolve cluster DNS, verify `dnsPolicy: ClusterFirstWithHostNet` is set. This is critical for pods using `hostNetwork: true`.

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
    wwid "iqn.2020-05.com.thoughtexpo:storage.*"
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

## File Structure

```
oss/iscsi/
├── Containerfile          # Fedora 43 with targetcli and debug tools
├── config.env            # Configuration (IQN/device prefixes now hardcoded)
├── generate.sh           # Main generator (reads from scripts/)
├── resources.yaml        # Generated (543 lines, 9 K8s resources)
├── validate.sh           # Post-deployment validation
├── README.md             # This file
├── summary.txt           # Design document with live testing insights
└── scripts/              # Externalized for IDE syntax highlighting
    ├── sts-global.sh     # Global target entrypoint
    ├── sts-zonal.sh      # Zonal target entrypoint
    └── ds-init.sh        # Initiator entrypoint
```

## License

MIT

## Contributing

Contributions welcome! Please ensure:
- Scripts remain zero-dependency (pure Bash)
- Follow existing patterns for heredocs and indentation
- Test with both global and zonal configurations
- Update documentation for new features
- Scripts in `scripts/` directory maintain full IDE syntax highlighting