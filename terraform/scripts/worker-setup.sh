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
yum install -y git curl wget vim htop python3 python3-pip

if ! command -v node >/dev/null 2>&1; then
  log "Installing Node.js 18"
  curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
  yum install -y nodejs
fi

if [ ! -d /opt/quickstart ]; then
  log "Cloning Alchemyst quickstart repository"
  git clone https://github.com/Alchemyst-ai/quickstart.git /opt/quickstart || log "Quickstart clone failed; worker wrapper will still run"
fi

mkdir -p /opt/alchemyst-worker
cd /opt/alchemyst-worker

cat > package.json <<'EOF'
{
  "name": "alchemyst-worker",
  "version": "1.0.0",
  "private": true,
  "main": "worker.js",
  "scripts": {
    "start": "node worker.js"
  },
  "dependencies": {
    "express": "^4.21.2"
  }
}
EOF

cat > worker.js <<'EOF'
const express = require('express');

const app = express();
app.use(express.json({ limit: '1mb' }));

const workerIndex = Number(process.env.WORKER_INDEX || 0);
const workerPort = Number(process.env.WORKER_PORT || 9000);
const workerType = process.env.WORKER_TYPE || (workerIndex % 2 === 0 ? 'python' : 'typescript');
const apiGatewayIp = process.env.API_GATEWAY_IP || 'unknown';

app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'ok',
    worker_index: workerIndex,
    worker_type: workerType,
    api_gateway_ip: apiGatewayIp,
    uptime: process.uptime(),
    timestamp: new Date().toISOString(),
  });
});

app.post('/infer', (req, res) => {
  const start = Date.now();
  const { prompt, model = 'llama' } = req.body || {};

  if (!prompt || typeof prompt !== 'string') {
    return res.status(400).json({
      error: 'Missing or invalid "prompt" field',
      timestamp: new Date().toISOString(),
    });
  }

  res.status(200).json({
    result: `[$${workerType}-worker-$${workerIndex}] Received prompt for model "$${model}": $${prompt}`,
    model,
    worker_index: workerIndex,
    worker_type: workerType,
    duration_ms: Date.now() - start,
    timestamp: new Date().toISOString(),
  });
});

app.listen(workerPort, '0.0.0.0', () => {
  console.log(`Alchemyst $${workerType} worker $${workerIndex} listening on 0.0.0.0:$${workerPort}`);
});

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
EOF

if [ $((WORKER_INDEX % 2)) -eq 0 ]; then
  WORKER_TYPE="python"
else
  WORKER_TYPE="typescript"
fi

cat > .env <<EOF
WORKER_INDEX=$WORKER_INDEX
WORKER_PORT=$WORKER_PORT
WORKER_HOST=0.0.0.0
WORKER_TYPE=$WORKER_TYPE
API_GATEWAY_IP=$API_GATEWAY_IP
LOG_LEVEL=info
EOF

log "Installing worker dependencies"
npm install --omit=dev
chown -R ec2-user:ec2-user /opt/alchemyst-worker /opt/quickstart 2>/dev/null || true

cat > /etc/systemd/system/alchemyst-worker.service <<'EOF'
[Unit]
Description=Alchemyst Worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/alchemyst-worker
EnvironmentFile=/opt/alchemyst-worker/.env
ExecStart=/usr/bin/node worker.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=alchemyst-worker

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable alchemyst-worker
systemctl restart alchemyst-worker

for attempt in $(seq 1 30); do
  if curl -fsS "http://localhost:$WORKER_PORT/health" >/dev/null; then
    log "Worker is healthy"
    exit 0
  fi
  log "Waiting for worker health check, attempt $attempt"
  sleep 2
done

log "Worker did not become healthy during setup"
systemctl status alchemyst-worker --no-pager || true
exit 1
