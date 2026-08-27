# Ansible control node.
#
# Ansible cannot run natively on Windows - the control node must be POSIX - and
# no general-purpose WSL distro is installed on this host (only Docker
# Desktop's own minimal one). A container is therefore the control node, which
# also pins the Ansible version so a rerun months later behaves identically.
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ansible \
      openssh-client \
      python3 \
      python3-jmespath \
      jq \
      curl \
      iputils-ping \
      netcat-openbsd \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work/ansible
ENTRYPOINT ["/bin/bash", "-lc"]
