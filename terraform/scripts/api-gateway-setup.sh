#!/bin/bash
set -euo pipefail

API_PORT=${api_gateway_port}

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/alchemyst-api-gateway.log
}

log "Starting API gateway setup"

yum update -y
yum install -y git curl wget vim htop

if ! command -v node >/dev/null 2>&1; then
  log "Installing Node.js 18"
  curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
  yum install -y nodejs
fi

mkdir -p /opt/alchemyst-api/config
cd /opt/alchemyst-api

cat > package.json <<'EOF'
{
  "name": "alchemyst-api-gateway",
  "version": "1.0.0",
  "private": true,
  "main": "src/api-gateway.js",
  "scripts": {
    "start": "node src/api-gateway.js"
  },
  "dependencies": {
    "axios": "^1.7.9",
    "dotenv": "^16.4.7",
    "express": "^4.21.2"
  }
}
EOF

mkdir -p src
cat > src/api-gateway.js <<'EOF'
const express = require('express');
const axios = require('axios');
const fs = require('fs');
require('dotenv').config();

const app = express();
app.use(express.json({ limit: '1mb' }));

const API_PORT = Number(process.env.API_PORT || 8000);
const API_HOST = process.env.API_HOST || '0.0.0.0';
const WORKER_CONFIG_PATH = process.env.WORKER_CONFIG_PATH || '/opt/alchemyst-api/config/workers.json';
const REQUEST_TIMEOUT = Number(process.env.REQUEST_TIMEOUT || 60000);

let WORKERS = {};

function loadWorkerConfig() {
  const raw = fs.readFileSync(WORKER_CONFIG_PATH, 'utf8');
  const config = JSON.parse(raw);
  WORKERS = config.workers.reduce((acc, worker) => {
    acc[worker.name] = {
      host: worker.host,
      port: worker.port,
      type: worker.type,
      timeout: worker.timeout || 30000,
    };
    return acc;
  }, {});
  console.log(`Loaded $${Object.keys(WORKERS).length} workers from $${WORKER_CONFIG_PATH}`);
}

app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    workers: Object.keys(WORKERS).length,
  });
});

app.get('/workers', async (req, res) => {
  const statuses = await Promise.all(Object.entries(WORKERS).map(async ([name, config]) => {
    try {
      const response = await axios.get(`http://$${config.host}:$${config.port}/health`, { timeout: 5000 });
      return {
        name,
        host: config.host,
        port: config.port,
        type: config.type,
        status: 'healthy',
        response: response.data,
      };
    } catch (error) {
      return {
        name,
        host: config.host,
        port: config.port,
        type: config.type,
        status: 'unhealthy',
        error: error.message,
      };
    }
  }));

  res.status(200).json({
    workers: statuses,
    timestamp: new Date().toISOString(),
  });
});

function chooseWorker(requestedWorker) {
  if (requestedWorker) {
    return [requestedWorker, WORKERS[requestedWorker]];
  }

  const firstWorker = Object.keys(WORKERS)[0];
  return [firstWorker, WORKERS[firstWorker]];
}

app.post('/infer', async (req, res) => {
  const startTime = Date.now();

  try {
    const { prompt, model = 'llama', worker: requestedWorker } = req.body || {};

    if (!prompt || typeof prompt !== 'string' || prompt.trim() === '') {
      return res.status(400).json({
        error: 'Missing or invalid "prompt" field',
        received: { prompt },
        timestamp: new Date().toISOString(),
      });
    }

    if (!model || typeof model !== 'string') {
      return res.status(400).json({
        error: 'Missing or invalid "model" field',
        timestamp: new Date().toISOString(),
      });
    }

    const [selectedWorker, workerConfig] = chooseWorker(requestedWorker);
    if (!workerConfig) {
      return res.status(400).json({
        error: `Worker "$${selectedWorker}" not found`,
        availableWorkers: Object.keys(WORKERS),
        timestamp: new Date().toISOString(),
      });
    }

    const workerUrl = `http://$${workerConfig.host}:$${workerConfig.port}/infer`;
    console.log(`[$${new Date().toISOString()}] Forwarding inference to $${selectedWorker} at $${workerUrl}`);

    const workerResponse = await axios.post(workerUrl, { prompt, model }, { timeout: REQUEST_TIMEOUT });
    const duration = Date.now() - startTime;

    res.status(200).json({
      prompt,
      model,
      result: workerResponse.data.result || workerResponse.data,
      worker: {
        name: selectedWorker,
        type: workerConfig.type,
        host: workerConfig.host,
        port: workerConfig.port,
      },
      duration_ms: duration,
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    const duration = Date.now() - startTime;
    const status = error.code === 'ECONNREFUSED' || error.code === 'ENOTFOUND'
      ? 503
      : error.code === 'ETIMEDOUT' || error.message.includes('timeout')
        ? 504
        : 500;

    res.status(status).json({
      error: status === 503 ? 'Worker unavailable' : status === 504 ? 'Worker request timeout' : 'Inference failed',
      details: error.message,
      duration_ms: duration,
      timestamp: new Date().toISOString(),
    });
  }
});

app.use((req, res) => {
  res.status(404).json({
    error: 'Not found',
    path: req.path,
    availableEndpoints: ['GET /health', 'GET /workers', 'POST /infer'],
    timestamp: new Date().toISOString(),
  });
});

loadWorkerConfig();

app.listen(API_PORT, API_HOST, () => {
  console.log(`Alchemyst API Gateway listening on http://$${API_HOST}:$${API_PORT}`);
});

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
EOF

cat > config/workers.json <<'EOF'
${workers_json}
EOF

cat > .env <<EOF
NODE_ENV=production
API_PORT=$API_PORT
API_HOST=0.0.0.0
WORKER_CONFIG_PATH=/opt/alchemyst-api/config/workers.json
REQUEST_TIMEOUT=60000
LOG_LEVEL=info
EOF

log "Installing API gateway dependencies"
npm install --omit=dev

if [ ! -d /opt/quickstart ]; then
  log "Cloning Alchemyst quickstart repository"
  git clone https://github.com/Alchemyst-ai/quickstart.git /opt/quickstart || log "Quickstart clone failed; API wrapper will still run"
fi

chown -R ec2-user:ec2-user /opt/alchemyst-api /opt/quickstart 2>/dev/null || true

cat > /etc/systemd/system/api-gateway.service <<'EOF'
[Unit]
Description=Alchemyst API Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/alchemyst-api
EnvironmentFile=/opt/alchemyst-api/.env
ExecStart=/usr/bin/node src/api-gateway.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=api-gateway

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable api-gateway
systemctl restart api-gateway

for attempt in $(seq 1 30); do
  if curl -fsS "http://localhost:$API_PORT/health" >/dev/null; then
    log "API gateway is healthy"
    exit 0
  fi
  log "Waiting for API gateway health check, attempt $attempt"
  sleep 2
done

log "API gateway did not become healthy during setup"
systemctl status api-gateway --no-pager || true
exit 1
