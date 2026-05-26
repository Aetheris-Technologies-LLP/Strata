const express = require('express');
const cors = require('cors');
require('dotenv').config();

const app = express();
app.use(cors());
app.use(express.json({ limit: '50mb' }));

const PORT = process.env.STRATA_PORT || 11435;
const OLLAMA_URL = process.env.OLLAMA_URL || 'http://10.0.0.238:11434';

// ═══════════════════════════════════════
// MODEL REGISTRY
// ═══════════════════════════════════════
const registry = {};

function registerModel(name, backendModel) {
  registry[name] = { name, backendModel: backendModel || name };
  console.log(`📦 Registered: ${name}`);
}

registerModel('mixtral', 'mixtral');
registerModel('aetheris-v1', 'aetheris-v1');

// ═══════════════════════════════════════
// REQUEST QUEUE
// ═══════════════════════════════════════
let running = false;
const pending = [];

function enqueue(fn) {
  return new Promise((resolve, reject) => {
    pending.push({ fn, resolve, reject });
    processQueue();
  });
}

async function processQueue() {
  if (running || pending.length === 0) return;
  running = true;
  const { fn, resolve, reject } = pending.shift();
  try {
    resolve(await fn());
  } catch (err) {
    reject(err);
  } finally {
    running = false;
    processQueue();
  }
}

// ═══════════════════════════════════════
// TENANT REGISTRY
// ═══════════════════════════════════════
const tenants = new Set(['*']);

function isAuthorized(tenantId) {
  return tenants.has('*') || tenants.has(tenantId);
}

// ═══════════════════════════════════════
// INFERENCE ENDPOINT
// ═══════════════════════════════════════
app.post('/api/generate', async (req, res) => {
  const tenantId = req.headers['x-tenant-id'] || 'default';

  if (!isAuthorized(tenantId)) {
    return res.status(401).json({ error: 'Unauthorized tenant' });
  }

  const { model, prompt, stream, options } = req.body;
  const entry = registry[model];

  if (!entry) {
    return res.status(404).json({ error: `Model not found: ${model}` });
  }

  console.log(`🌊 Strata — model: ${model}, tenant: ${tenantId}, prompt: ${prompt?.length} chars`);

  try {
    const result = await enqueue(async () => {
      const response = await fetch(`${OLLAMA_URL}/api/generate`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        signal: AbortSignal.timeout(240000),
        body: JSON.stringify({
          model: entry.backendModel,
          prompt,
          stream: false,
          options: options || { temperature: 0.1 }
        })
      });
      if (!response.ok) throw new Error(`Backend error: ${response.status}`);
      return await response.json();
    });

    console.log(`✅ Strata response: ${result.response?.length || 0} chars`);
    res.json(result);

  } catch (err) {
    console.error(`❌ Strata failed:`, err.message);
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════
// MODEL MANAGEMENT
// ═══════════════════════════════════════
app.get('/api/tags', (req, res) => {
  res.json({ models: Object.values(registry).map(m => ({ name: m.name, model: m.name })) });
});

app.post('/api/models/register', (req, res) => {
  const { name, backendModel } = req.body;
  if (!name) return res.status(400).json({ error: 'name required' });
  registerModel(name, backendModel);
  res.json({ success: true, model: registry[name] });
});

app.post('/api/tenants/add', (req, res) => {
  const { tenantId } = req.body;
  if (!tenantId) return res.status(400).json({ error: 'tenantId required' });
  tenants.add(tenantId);
  res.json({ success: true, tenants: Array.from(tenants) });
});

// ═══════════════════════════════════════
// HEALTH CHECK
// ═══════════════════════════════════════
app.get('/health', (req, res) => {
  res.json({
    status: 'online',
    version: '0.1.0',
    queue: { pending: pending.length, running },
    models: Object.keys(registry),
    tenants: Array.from(tenants)
  });
});

app.listen(PORT, () => {
  console.log(`\n🌊 Strata v0.1.0 running on port ${PORT}\n📦 Models: ${Object.keys(registry).join(', ')}\n🔗 Backend: ${OLLAMA_URL}\n`);
});
