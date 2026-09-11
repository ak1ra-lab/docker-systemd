# Generated from templates/Dockerfile.debian.j2 by hack/generate.py -- do not edit.
# Source of truth: matrix.yaml (debian 12).
FROM docker.io/library/debian:12

LABEL org.opencontainers.image.title="Debian 12 (bookworm)" \
      org.opencontainers.image.description="systemd-enabled Linux distribution containers for Ansible Molecule managed nodes" \
      org.opencontainers.image.source="https://github.com/ak1ra-lab/docker-systemd" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/debian:12"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        dbus \
        iproute2 \
        procps \
        python3 \
        python3-apt \
        sudo \
        systemd \
        systemd-sysv \
    && apt-get clean \
    && rm -f /var/lib/dbus/machine-id \
    && : > /etc/machine-id

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
