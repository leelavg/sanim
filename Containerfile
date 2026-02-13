FROM registry.fedoraproject.org/fedora:43

# Install packages:
# - targetcli: iSCSI target configuration (targets only)
# - util-linux: nsenter, lsblk, mount
# - procps-ng: ps, top
# - iproute: ss, ip
# Good to have for debugging:
# - bind-utils: nslookup, dig (DNS debugging)
# - iputils: ping
# - tcpdump: network debugging
RUN dnf install -y \
    targetcli \
    util-linux \
    procps-ng \
    iproute \
    bind-utils \
    iputils \
    tcpdump \
    && dnf clean all

# Note: iscsi-initiator-utils NOT needed - we use nsenter to host's iscsiadm

# Create required directories
RUN mkdir -p /etc/target

# Default command
CMD ["/bin/bash"]
