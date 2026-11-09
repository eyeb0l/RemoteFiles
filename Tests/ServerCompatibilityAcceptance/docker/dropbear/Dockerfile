# Dropbear with OpenSSH's sftp-server, as on routers and small embedded storage devices.
FROM alpine:3.20
RUN apk add --no-cache dropbear dropbear-convert openssh-sftp-server \
    && adduser -D -h /home/fixture -s /bin/sh fixture && sed -i 's/^fixture:!/fixture:*/' /etc/shadow
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
