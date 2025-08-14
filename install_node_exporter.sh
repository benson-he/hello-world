#!/bin/bash
set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

for cmd in curl tar file systemctl; do
  command -v $cmd >/dev/null 2>&1 || { echo "$cmd not found."; exit 1; }
done

cd /tmp

curl -fsSL -o node_exporter.tar.gz https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
file node_exporter.tar.gz | grep -q 'gzip compressed data' || { log "Downloaded file not valid"; exit 1; }

tar xzf node_exporter.tar.gz
install -m 0755 node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/node_exporter
rm -rf node_exporter-1.8.2.linux-amd64 node_exporter.tar.gz

command -v sestatus >/dev/null 2>&1 && sestatus | grep -q 'enabled' && \
  (chcon -t bin_t /usr/local/bin/node_exporter 2>/dev/null || chcon -t usr_t /usr/local/bin/node_exporter)

cat << EOF > /etc/systemd/system/node-exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=root
ExecStartPre=/bin/test -x /usr/local/bin/node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node-exporter

if systemctl is-active --quiet node-exporter; then
  log "Node Exporter started successfully"
else
  log "Error: Failed to start Node Exporter"
  journalctl -u node-exporter --no-pager -n 20
  exit 1
fi
