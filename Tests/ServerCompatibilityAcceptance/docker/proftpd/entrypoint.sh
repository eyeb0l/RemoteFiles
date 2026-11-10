set -eu
mkdir -p /srv /etc/remotefiles
cp -a /fixture/files /fixture/outside.txt /srv/
chown -R root:root /srv && chmod -R a+rX /srv
install -m 600 /fixture/host /etc/remotefiles/host
# mod_sftp reads authorised keys in RFC 4716 form.
ssh-keygen -e -f /fixture/client.pub > /etc/remotefiles/authorized_keys
cat > /etc/remotefiles/proftpd.conf <<CONF
ServerType standalone
DefaultServer on
Port 2222
User nobody
Group nogroup
UseIPv6 off
RequireValidShell off
WtmpLog off
ScoreboardFile /run/proftpd.scoreboard
PidFile /run/proftpd.pid
LoadModule mod_sftp.c
DefaultRoot /srv
SFTPEngine on
SFTPLog /var/log/proftpd-sftp.log
SFTPHostKey /etc/remotefiles/host
SFTPAuthorizedUserKeys file:/etc/remotefiles/authorized_keys
SFTPAuthMethods publickey
SFTPMaxChannels ${CHANNELS:-10}
<Limit WRITE SITE_CHMOD>
  DenyAll
</Limit>
CONF
# mod_sftp will not log to a symlink such as /proc/self/fd/2; stream its file into the container log instead.
touch /var/log/proftpd-sftp.log && tail -F /var/log/proftpd-sftp.log &
exec proftpd --nodaemon --config /etc/remotefiles/proftpd.conf
