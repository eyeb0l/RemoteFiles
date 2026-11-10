# ProFTPD's mod_sftp: an SFTP/SSH implementation independent of OpenSSH, used by hosting and some appliances.
FROM debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends proftpd-core proftpd-mod-crypto openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -M -d /srv/files -s /bin/false fixture && usermod -p '*' fixture
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
