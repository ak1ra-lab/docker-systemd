# Generated from templates/Dockerfile.rhel.j2 by hack/generate.py -- do not edit.
# Source of truth: matrix.yaml (rocky 9).
FROM docker.io/rockylinux/rockylinux:9

LABEL org.opencontainers.image.title="Rocky Linux 9" \
      org.opencontainers.image.description="systemd-enabled Linux distribution containers for Ansible Molecule managed nodes" \
      org.opencontainers.image.source="https://github.com/ak1ra-lab/docker-systemd" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/rockylinux/rockylinux:9"

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
