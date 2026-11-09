# SFTPGo: a Go SFTP server with its own SSH stack and virtual file system, offered by NAS app catalogues.
FROM drakkan/sftpgo:v2.6.6-alpine
USER root
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
