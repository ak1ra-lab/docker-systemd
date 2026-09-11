# Generated from templates/Dockerfile.rhel.j2 by hack/generate.py -- do not edit.
# Source of truth: matrix.yaml (centos-stream 10).
FROM quay.io/centos/centos:stream10

LABEL org.opencontainers.image.title="CentOS Stream 10" \
      org.opencontainers.image.description="systemd-enabled Linux distribution containers for Ansible Molecule managed nodes" \
      org.opencontainers.image.source="https://github.com/ak1ra-lab/docker-systemd" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="quay.io/centos/centos:stream10"

RUN dnf install -y \
        ca-certificates \
        dbus-broker \
        iproute \
        procps-ng \
        python3 \
        python3-dnf \
        sudo \
        systemd \
    && dnf clean packages \
    && rm -f /var/lib/dbus/machine-id \
    && : > /etc/machine-id

RUN systemctl enable dbus-broker.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
