#!/bin/bash
set -euo pipefail

WORKER_INDEX=${worker_index}
WORKER_PORT=${worker_port}
API_GATEWAY_IP=${api_gateway_ip}

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/alchemyst-worker.log
}

log "Starting worker setup: index=$WORKER_INDEX port=$WORKER_PORT api_gateway=$API_GATEWAY_IP"

yum update -y
yum install -y git curl wget vim htop python3 python3-pip gcc python3-devel

if ! command -v node >/dev/null 2>&1; then
  log "Installing Node.js 18"
  curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
  yum install -y nodejs
fi

if [ ! -d /opt/hiring ]; then
  log "Cloning Alchemyst hiring repository with official quickstart"
  git clone --depth 1 https://github.com/Alchemyst-ai/hiring.git /opt/hiring
fi

if [ $((WORKER_INDEX % 2)) -eq 0 ]; then
  WORKER_TYPE="python"
  WORKER_DIR="/opt/hiring/may-2026/devops/quickstart/workers/inference-worker"
  WORKER_CMD="/usr/bin/python3 inference_worker.py"
else
  WORKER_TYPE="typescript"
  WORKER_DIR="/opt/hiring/may-2026/devops/quickstart/workers/caller-worker"
  WORKER_CMD="/usr/bin/npm run dev"
fi

cat > /etc/alchemyst-worker.env <<EOF
WORKER_INDEX=$WORKER_INDEX
WORKER_PORT=$WORKER_PORT
WORKER_HOST=0.0.0.0
WORKER_TYPE=$WORKER_TYPE
API_GATEWAY_IP=$API_GATEWAY_IP
III_URL=ws://$API_GATEWAY_IP:49134
LOG_LEVEL=info
EOF

log "Installing official quickstart worker dependencies for $WORKER_TYPE"
cd "$WORKER_DIR"
if [ "$WORKER_TYPE" = "python" ]; then
  pip3 install --upgrade pip
  pip3 install -r requirements.txt
else
  npm install
fi
chown -R ec2-user:ec2-user /opt/hiring 2>/dev/null || true

cat > /etc/systemd/system/alchemyst-worker.service <<'EOF'
[Unit]
Description=Alchemyst Official Quickstart Worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=__WORKER_DIR__
EnvironmentFile=/etc/alchemyst-worker.env
ExecStart=__WORKER_CMD__
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=alchemyst-worker

[Install]
WantedBy=multi-user.target
EOF

sed -i "s#__WORKER_DIR__#$WORKER_DIR#g" /etc/systemd/system/alchemyst-worker.service
sed -i "s#__WORKER_CMD__#$WORKER_CMD#g" /etc/systemd/system/alchemyst-worker.service

systemctl daemon-reload
systemctl enable alchemyst-worker
systemctl restart alchemyst-worker

for attempt in $(seq 1 30); do
  if systemctl is-active --quiet alchemyst-worker; then
    log "$WORKER_TYPE quickstart worker service is active"
    exit 0
  fi
  log "Waiting for worker service, attempt $attempt"
  sleep 2
done

log "Worker did not become healthy during setup"
systemctl status alchemyst-worker --no-pager || true
exit 1
