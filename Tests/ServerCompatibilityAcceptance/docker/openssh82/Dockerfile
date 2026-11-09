# OpenSSH 8.2p1 (Ubuntu 20.04), configured as NAS firmware commonly is: chrooted, SFTP only, no shell or exec.
FROM ubuntu:20.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd \
    && useradd -M -d /files -s /usr/sbin/nologin fixture && usermod -p '*' fixture
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
