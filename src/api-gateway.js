const express = require('express');
const axios = require('axios'); 
const fs = require('fs');
require('dotenv').config();

const app = express();
app.use(express.json({ limit: '1mb' })); 

const API_PORT = Number(process.env.API_PORT || 8000);
const API_HOST = process.env.API_HOST || '0.0.0.0';
const WORKER_CONFIG_PATH = process.env.WORKER_CONFIG_PATH || './config/workers.json';
const III_HTTP_URL = process.env.III_HTTP_URL || 'http://127.0.0.1:3111';
const REQUEST_TIMEOUT = Number(process.env.REQUEST_TIMEOUT || 60000);

let WORKERS = {};

function loadWorkerConfig() {
  if (!fs.existsSync(WORKER_CONFIG_PATH)) {
    throw new Error(`Worker config not found at ${WORKER_CONFIG_PATH}`);
  }

  const config = JSON.parse(fs.readFileSync(WORKER_CONFIG_PATH, 'utf8'));
  WORKERS = config.workers.reduce((acc, worker) => {
    acc[worker.name] = {
      host: worker.host,
      port: worker.port,
      type: worker.type,
      timeout: worker.timeout || 30000,
    };
    return acc;
  }, {});
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
    const workerResponse = await axios.post(
      `${III_HTTP_URL}/v1/chat/completions`,
      { model, messages: chatMessages },
      { timeout: REQUEST_TIMEOUT }
    );
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

    if (error.code === 'ECONNREFUSED' || error.code === 'ENOTFOUND') {
      return res.status(503).json({
        error: 'Worker unavailable',
        details: error.message,
        duration_ms: duration,
        timestamp: new Date().toISOString(),
      });
    }

    if (error.code === 'ETIMEDOUT' || error.message.includes('timeout')) {
      return res.status(504).json({
        error: 'Worker request timeout',
        details: error.message,
        duration_ms: duration,
        timestamp: new Date().toISOString(),
      });
    }

    res.status(500).json({
      error: 'Inference failed',
      details: error.message,
      duration_ms: duration,
      timestamp: new Date().toISOString(),
    });
  }
});

app.use((err, req, res, next) => {
  res.status(500).json({
    error: 'Internal server error',
    message: err.message,
    timestamp: new Date().toISOString(),
  });
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
  console.log(`Alchemyst API Gateway listening on http://${API_HOST}:${API_PORT}`);
});

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
