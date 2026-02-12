FROM registry.fedoraproject.org/fedora:43

# Install required packages for iSCSI target and initiator operations
RUN dnf install -y \
    util-linux \
    targetcli \
    iscsi-initiator-utils \
    hostname \
    procps-ng \
    iproute \
    jq \
    && dnf clean all

# Create required directories
RUN mkdir -p /etc/target /var/lib/iscsi /etc/iscsi

# Default command
CMD ["/bin/bash"]
