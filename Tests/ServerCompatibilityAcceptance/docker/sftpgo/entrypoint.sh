set -eu
mkdir -p /srv /etc/remotefiles
cp -a /fixture/files /fixture/outside.txt /srv/
chmod -R a+rX /srv
install -m 600 /fixture/host /etc/remotefiles/host
key=$(cat /fixture/client.pub)
# WRITABLE=1 lets the account write in /uploads, for the upload check; it is read-only everywhere else.
uploads=""; if [ "${WRITABLE:-0}" = 1 ]; then uploads=', "/uploads": ["*"]'; chmod -R a+rwX /srv/files/uploads; fi
cat > /etc/remotefiles/data.json <<JSON
{"users": [{"id": 1, "status": 1, "username": "fixture", "public_keys": ["$key"], "home_dir": "/srv/files",
            "permissions": {"/": ["list", "download"]$uploads}}], "folders": [], "admins": []}
JSON
export SFTPGO_DATA_PROVIDER__DRIVER=memory SFTPGO_DATA_PROVIDER__NAME=/etc/remotefiles/data.json
export SFTPGO_SFTPD__BINDINGS__0__PORT=2222 SFTPGO_SFTPD__HOST_KEYS=/etc/remotefiles/host
export SFTPGO_HTTPD__BINDINGS__0__PORT=0 SFTPGO_TELEMETRY__BIND_PORT=0 SFTPGO_LOG_FILE_PATH=""
exec sftpgo serve --log-level debug
