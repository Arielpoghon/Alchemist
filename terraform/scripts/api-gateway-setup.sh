#!/bin/bash
set -euo pipefail

API_PORT=${api_gateway_port}

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/alchemyst-api-gateway.log
}

log "Starting API gateway setup"

yum update -y
yum install -y git curl wget vim htop docker

systemctl enable docker
systemctl start docker

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
const III_HTTP_URL = process.env.III_HTTP_URL || 'http://127.0.0.1:3111';
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
  let engineHealth = { status: 'unknown' };
  try {
    const response = await axios.get(`${III_HTTP_URL}/health`, { timeout: 5000 });
    engineHealth = response.data;
  } catch (error) {
    engineHealth = { status: 'unhealthy', error: error.message };
  }

  res.status(200).json({
    engine: engineHealth,
    workers: Object.entries(WORKERS).map(([name, config]) => ({
      name,
      host: config.host,
      port: config.port,
      type: config.type,
      transport: 'iii websocket',
      status: 'registered dynamically with iii engine',
    })),
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
    const { prompt, model = 'gemma-3-270m', messages } = req.body || {};

    if ((!prompt || typeof prompt !== 'string' || prompt.trim() === '') && !Array.isArray(messages)) {
      return res.status(400).json({
        error: 'Missing or invalid "prompt" field, or provide a chat "messages" array',
        received: { prompt, messages },
        timestamp: new Date().toISOString(),
      });
    }

    if (!model || typeof model !== 'string') {
      return res.status(400).json({
        error: 'Missing or invalid "model" field',
        timestamp: new Date().toISOString(),
      });
    }

    const chatMessages = Array.isArray(messages) ? messages : [{ role: 'user', content: prompt }];
    const workerUrl = `$${III_HTTP_URL}/v1/chat/completions`;
    console.log(`[$${new Date().toISOString()}] Forwarding inference to iii HTTP trigger at $${workerUrl}`);

    const workerResponse = await axios.post(workerUrl, { model, messages: chatMessages }, { timeout: REQUEST_TIMEOUT });
    const duration = Date.now() - startTime;

    res.status(200).json({
      prompt: prompt || chatMessages[chatMessages.length - 1]?.content,
      messages: chatMessages,
      model,
      result: workerResponse.data.result || workerResponse.data,
      worker: {
        mesh: 'iii',
        path: 'caller-worker -> inference-worker',
        endpoint: '/v1/chat/completions',
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
III_HTTP_URL=http://127.0.0.1:3111
REQUEST_TIMEOUT=60000
LOG_LEVEL=info
EOF

log "Installing API gateway dependencies"
npm install --omit=dev

if [ ! -d /opt/hiring ]; then
  log "Cloning Alchemyst hiring repository with official quickstart"
  git clone --depth 1 https://github.com/Alchemyst-ai/hiring.git /opt/hiring || log "Quickstart clone failed; API wrapper will still run"
fi

cat > /etc/systemd/system/iii-engine.service <<'EOF'
[Unit]
Description=iii Engine for Alchemyst quickstart
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f iii-engine
ExecStart=/usr/bin/docker run --name iii-engine --rm -p 127.0.0.1:3111:3111 -p 49134:49134 iiidev/iii:latest --use-default-config
ExecStop=/usr/bin/docker stop iii-engine
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=iii-engine

[Install]
WantedBy=multi-user.target
EOF

chown -R ec2-user:ec2-user /opt/alchemyst-api /opt/hiring 2>/dev/null || true

cat > /etc/systemd/system/api-gateway.service <<'EOF'
[Unit]
Description=Alchemyst API Gateway
After=iii-engine.service network-online.target
Wants=iii-engine.service network-online.target

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
systemctl enable iii-engine
systemctl restart iii-engine
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
