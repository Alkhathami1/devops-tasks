# The "Linux machine" for Task 01.
#
# Debian rather than Alpine: cifs-utils, samba and xfsprogs are all first-class
# here, and the SMB stack in particular behaves closer to a real server distro.
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      cifs-utils \
      samba \
      samba-common-bin \
      smbclient \
      xfsprogs \
      sysstat \
      procps \
      iproute2 \
      iputils-ping \
      netcat-openbsd \
      curl \
      ca-certificates \
      fio \
 && rm -rf /var/lib/apt/lists/*

# node_exporter is copied from the official image rather than downloaded, so it
# is version-pinned and needs no network at build time.
#
# It runs INSIDE this container on purpose. A separate node-exporter container
# has its own mount namespace and would never see a CIFS or XFS mount made in
# here - it would report the host's filesystems and silently omit the very
# mounts this task is about. node_exporter belongs on the machine it monitors,
# which is exactly what this is.
COPY --from=prom/node-exporter:v1.8.2 /bin/node_exporter /usr/local/bin/node_exporter

# Samba configuration: SMB3 only, encryption required. See smb.conf for why.
COPY smb.conf /etc/samba/smb.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY cifs-metrics.sh /usr/local/bin/cifs-metrics.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/cifs-metrics.sh

# Where the exported share and the XFS image live.
RUN mkdir -p /srv/share /mnt/winshare /mnt/xfs /var/log/task01

EXPOSE 445

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
