# sanim - SAN Simulator

**sanim** (SAN Simulator) is a zero-dependency Bash generator that provides iSCSI block storage on AWS/OpenShift clusters using Fedora 43 containers. Battle-tested through live cluster deployment with comprehensive fixes applied.

## Overview

sanim enables you to quickly provision iSCSI block storage within your Kubernetes/OpenShift cluster for testing, development, or ephemeral workloads. It uses StatefulSets as iSCSI targets and a DaemonSet as a "dumb" initiator controller.

## Architecture

**Components:**
- **STS-Global** (optional): Single-replica StatefulSet on port 3260, auto-uses first zone from zones.txt
- **STS-Zonal** (optional): Per-zone StatefulSets on port 3261, one per zone in zones.txt
- **DS-Initiator**: DaemonSet with sysfs-based health checks (10s interval) and auto-recovery
- **Headless Services**: Stable pod DNS (global-0.global-service, zonal-{zone}-0.zonal-{zone}-service)
- **ConfigMaps**: Entrypoint scripts + node-zone-map
- **SCCs**: Separate SecurityContextConstraints for targets (hostNetwork, hostPorts) and initiators (hostPID)

**Key Design:**
- Pod networking for targets (not hostNetwork) - stable DNS, no port conflicts
- Port separation: global=3260, zonal=3261 (kernel binds at host level, not per-IQN)
- Zone map workflow: `generate.sh -m` queries cluster once, writes zones.txt + node-zone-map.yaml
- Session persistence: Host kernel manages iSCSI sessions, survives pod restarts
- nsenter pattern: Run host's iscsiadm from container (Fedora 43 incompatible with RHCOS)
- No clearconfig/restoreconfig: Prevented kernel listener thread from restarting
- Aggressive timeouts: noop_out_timeout=5s, replacement_timeout=15s
- Hardcoded IQN: `iqn.2020-05.com.thoughtexpo:storage` (domain registration date)
- Hardcoded device prefixes: `global-*` and `zonal-*`

**Flow:**
```
generate.sh -m → zones.txt + node-zone-map.yaml → oc apply node-zone-map.yaml
config.env → generate.sh → resources.yaml → oc apply resources.yaml
                                                ↓
                              ┌─────────────────┴─────────────────┐
                              ↓                                   ↓
                      STS (Target)                        DS (Initiator)
                      - targetcli config                  - nsenter iscsiadm
                      - Port 3260/3261                    - Sysfs monitoring
                      - LUNs via volumeDevices            - Host kernel sessions
```

## FAQ

**Why StatefulSets for targets?**
Provide stable DNS names (`global-0.global-service`), sticky PVCs across restarts, and zone affinity with `WaitForFirstConsumer`.

**Why is the DaemonSet "dumb"?**
It only runs `iscsiadm` login via `nsenter` - does NOT start `iscsid`. Host kernel manages sessions, so they survive pod restarts (no I/O disruption).

**Why use nsenter for iscsiadm?**
Fedora 43's iscsiadm (6.2.1.11) is incompatible with RHCOS kernel. `nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm` runs the host's version.

**Why different ports for global vs zonal?**
Port binding happens at host kernel level, not per-IQN. If global and zonal targets co-locate on same node, they'd conflict on port 3260. Solution: global=3260, zonal=3261.

**Target mounts:** volumeDevices for PVC block devices, /var/run/dbus (ro) for targetcli, /sys/kernel/config for configfs.

**Initiator mounts:** /dev, /etc/iscsi, /var/lib/iscsi with HostToContainer propagation. Sessions persist in host kernel across container restarts.

## Usage

### 1. Generate Zone Map

Query cluster for node-to-zone mapping (requires oc):

```bash
bash generate.sh -m
oc apply -f node-zone-map.yaml --server-side --force-conflicts
```

This creates `zones.txt` and `node-zone-map.yaml`.

### 2. Configure

Edit `config.env`:

```bash
NAMESPACE=sanim-system
INSTALL_GLOBAL=true
INSTALL_ZONAL=true
GLOBAL_DISK_COUNT=2
GLOBAL_DISK_SIZE=10Gi
ZONAL_DISK_COUNT=1
ZONAL_DISK_SIZE=10Gi
STORAGE_CLASS=gp3-csi
IMAGE=ghcr.io/leelavg/sanim:latest
NODE_LABEL_FILTER=node-role.kubernetes.io/worker=
```

**Hardcoded:** IQN=`iqn.2020-05.com.thoughtexpo:storage`, device prefixes=`global-*/zonal-*`, ports=3260/3261

### 3. Generate and Deploy

```bash
bash generate.sh  # Reads zones.txt offline, auto-selects first zone for global
oc apply -f resources.yaml --server-side --force-conflicts
```

### 4. Verify

```bash
# Check components
oc get sts,ds,pods -n sanim-system

# Verify iSCSI sessions on host kernel
oc exec -n sanim-system <initiator-pod> -- nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm --mode session

# Inspect all generated resources
grep '^#,' *.yaml
```

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `sanim-system` | Namespace for all resources |
| `INSTALL_GLOBAL` | `false` | Enable global shared target (uses first zone from zones.txt) |
| `INSTALL_ZONAL` | `false` | Enable zonal shared-nothing targets (one per zone in zones.txt) |
| `GLOBAL_DISK_COUNT` | `2` | Number of LUNs for global target |
| `GLOBAL_DISK_SIZE` | `10Gi` | Size of each global LUN |
| `ZONAL_DISK_COUNT` | `1` | Number of LUNs per zonal target |
| `ZONAL_DISK_SIZE` | `10Gi` | Size of each zonal LUN |
| `STORAGE_CLASS` | `gp3-csi` | StorageClass (must support volumeMode: Block) |
| `IMAGE` | `ghcr.io/leelavg/sanim:latest` | Container image |
| `NODE_LABEL_FILTER` | `node-role.kubernetes.io/worker=` | Node selector for initiators |
| `FORCE_CLEANUP` | `false` | Logout sessions on pod termination |

**Hardcoded:** IQN=`iqn.2020-05.com.thoughtexpo:storage`, devices=`global-*/zonal-*`, ports=3260/3261

**Zone management:** Run `generate.sh -m` first to create zones.txt (offline, no network calls during generation)

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

**IQN Format:** `iqn.YYYY-MM.reverse.domain:identifier`
- Global: `iqn.2020-05.com.thoughtexpo:storage:global`
- Zonal: `iqn.2020-05.com.thoughtexpo:storage:us-west-2b` (example)
- Initiator: `iqn.1994-05.com.redhat:{node}` (host)

**Target vs Initiator:**
- Target: STS pods export storage via targetcli
- Initiator: DS pods consume storage via host's iscsiadm

**Key Commands (via nsenter):**
```bash
# Discover targets
nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm --mode discovery --type sendtargets --portal <DNS>

# Login
nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm --mode node --targetname <IQN> --portal <DNS> --login

# View sessions
nsenter -t 1 -m -u -n -i /usr/sbin/iscsiadm --mode session
```

## Troubleshooting

**No LUNs in target:**
```bash
oc get pvc -n sanim-system  # Check PVCs bound
oc exec -n sanim-system <target-pod> -- ls -la /dev/global-* /dev/zonal-*
```

**Discovery failures:**
```bash
oc exec -n sanim-system <initiator-pod> -- getent hosts global-service.sanim-system.svc.cluster.local
oc exec -n sanim-system <target-pod> -- targetcli /iscsi ls
```

**Sessions not persisting:** Set `FORCE_CLEANUP=false`. Sessions survive pod restarts (host kernel manages them).

**Kernel logs (critical for login failures):**
```bash
# From node
oc debug node/<node> → chroot /host → dmesg | grep -i iscsi

# From pod (if /dev/kmsg accessible)
oc exec -n sanim-system <initiator-pod> -- cat /dev/kmsg | grep -i iscsi
```

Common errors: `detected conn error` (network), `session recovery timed out` (target unreachable), `Login failed` (config issue)

**Zone mismatch:** `oc get pods -n sanim-system -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.'topology\.kubernetes\.io/zone'`

**DNS issues:** Verify `dnsPolicy: ClusterFirstWithHostNet` for hostNetwork pods

## Security Considerations

- sanim requires privileged containers and host access
- Use only in trusted environments (dev/test clusters)
- Not recommended for production workloads
- No CHAP authentication configured by default

## Multipath Configuration

On OpenShift/RHCOS nodes with multipathd, blacklist sanim devices in `/etc/multipath.conf`:

```
blacklist {
    device {
        vendor "LIO-ORG"
        product ".*"
    }
}
```

Or by IQN: `wwid "iqn.2020-05.com.thoughtexpo:storage.*"`

Reload: `systemctl reload multipathd`

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
- **StorageClass with `volumeMode: Block` and `WaitForFirstConsumer` binding**
- Nodes with `topology.kubernetes.io/zone` labels
- Cluster admin (for SCC creation)

Verify: `oc get sc <your-class> -o yaml | grep -E 'volumeBindingMode|volumeMode'`

## File Structure

```
sanim/
├── Containerfile          # Fedora 43 + targetcli + debug tools
├── config.env            # User configuration
├── generate.sh           # Main generator (-m flag for zone mapping)
├── resources.yaml        # Generated K8s resources
├── validate.sh           # Post-deployment validation
├── README.md / summary.txt
└── scripts/              # Entrypoint scripts (IDE syntax highlighting)
    ├── sts-global.sh, sts-zonal.sh, ds-init.sh
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