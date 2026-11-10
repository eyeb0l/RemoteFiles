set -eu
mkdir -p /srv /etc/dropbear /home/fixture/.ssh
cp -a /fixture/files /fixture/outside.txt /srv/
chown -R root:root /srv && chmod -R a+rX /srv
install -m 600 -o fixture /fixture/client.pub /home/fixture/.ssh/authorized_keys
chown -R fixture /home/fixture && chmod 700 /home/fixture/.ssh
dropbearconvert openssh dropbear /fixture/host /etc/dropbear/host
exec dropbear -F -E -s -w -p 2222 -r /etc/dropbear/host
