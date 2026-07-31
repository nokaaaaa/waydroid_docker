# syntax=docker/dockerfile:1
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION} AS tools

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      adb android-sdk-platform-tools avahi-utils ca-certificates curl \
      iproute2 iputils-ping net-tools netcat-openbsd socat tcpdump \
 && rm -rf /var/lib/apt/lists/*

# adb keys are kept in a named volume; never bake credentials into the image.
ENV HOME=/home/waydroidop
RUN useradd --create-home --uid 10001 --user-group waydroidop
USER waydroidop
WORKDIR /work
CMD ["sleep", "infinity"]

# Unsupported research target: Waydroid(LXC) nested in Docker.
# Build/start only with: docker compose --profile experimental up nested-waydroid
FROM ubuntu:${UBUNTU_VERSION} AS waydroid-experimental
ENV DEBIAN_FRONTEND=noninteractive container=docker
STOPSIGNAL SIGRTMIN+3
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl dbus systemd systemd-sysv \
 && curl -fsSL https://repo.waydro.id | bash \
 && apt-get install -y --no-install-recommends waydroid weston \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask dev-hugepages.mount sys-fs-fuse-connections.mount systemd-remount-fs.service
VOLUME ["/var/lib/waydroid"]
CMD ["/sbin/init"]
