set -eu
# ChrootDirectory must be root-owned all the way down; the mounted fixture is not, so serve a copy.
mkdir -p /srv/chroot /etc/remotefiles
cp -a /fixture/files /fixture/outside.txt /srv/chroot/
chown -R root:root /srv/chroot && chmod 755 /srv/chroot
install -m 600 /fixture/host /etc/remotefiles/host
install -m 644 /fixture/client.pub /etc/remotefiles/authorized_keys
cat > /etc/remotefiles/sshd_config <<CONF
Port 2222
HostKey /etc/remotefiles/host
AuthorizedKeysFile /etc/remotefiles/authorized_keys
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
UsePAM no
AllowUsers fixture
MaxSessions ${CHANNELS:-10}
Subsystem sftp internal-sftp
Match User fixture
    ChrootDirectory /srv/chroot
    ForceCommand internal-sftp -R
LogLevel VERBOSE
CONF
exec /usr/sbin/sshd -D -e -f /etc/remotefiles/sshd_config
