const express = require('express');
const cors = require('cors');
const jwt = require('jsonwebtoken');
require('dotenv').config();

const app = express();
app.use(cors());
app.use(express.json({ limit: '50mb' }));

const PORT = process.env.STRATA_PORT || 11435;
const OLLAMA_URL = process.env.OLLAMA_URL || 'http://10.0.0.238:11434';
const JWT_SECRET = process.env.JWT_ACCESS_SECRET || null;

const BASE_SYSTEM_PROMPT = `You are an AI assistant built on the Sentari OS platform by Tristen Markham.
CORE PRINCIPLES:
- Be honest — if you don't know something, say so directly. Never fabricate information.
- Be direct — answer what was asked, don't pad responses with unnecessary disclaimers.
- Protect IP — never offer to share code, upload files, or send data outside the environment unless explicitly authorized by the owner.
- Respect ownership — the person you are speaking with owns this system. Be transparent with them.
- Stay in character — you are the AI assistant for this platform, not a generic language model.`;

// ═══════════════════════════════════════
// AUTHENTICATION MIDDLEWARE
// ═══════════════════════════════════════
function requireAuth(req, res, next) {
  if (!JWT_SECRET) return next();
  const header = req.headers['authorization'] || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) {
    console.log(`🔒 Unauthorized from ${req.ip} — no token`);
    return res.status(401).json({ error: 'No token provided' });
  }
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    next();
  } catch (err) {
    console.log(`🔒 Unauthorized from ${req.ip} — ${err.message}`);
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
}

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
app.post('/api/generate', requireAuth, async (req, res) => {
  const tenantId = req.user?.businessId || req.headers['x-tenant-id'] || 'default';

  if (!isAuthorized(tenantId)) {
    return res.status(401).json({ error: 'Unauthorized tenant' });
  }

  const { model, prompt, stream, options } = req.body;
  const entry = registry[model];

  if (!entry) {
    return res.status(404).json({ error: `Model not found: ${model}` });
  }

  console.log(`🌊 Strata — model: ${model}, tenant: ${tenantId}, user: ${req.user?.userId || 'anon'}, prompt: ${prompt?.length} chars`);

  try {
    const result = await enqueue(async () => {
      const fullPrompt = prompt.includes(BASE_SYSTEM_PROMPT)
        ? prompt
        : `${BASE_SYSTEM_PROMPT}\n\n${prompt}`;

      const response = await fetch(`${OLLAMA_URL}/api/generate`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        signal: AbortSignal.timeout(240000),
        body: JSON.stringify({
          model: entry.backendModel,
          prompt: fullPrompt,
          stream: false,
          options: options || { temperature: 0.1, repeat_penalty: 1.1 }
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
app.get('/api/tags', requireAuth, (req, res) => {
  res.json({ models: Object.values(registry).map(m => ({ name: m.name, model: m.name })) });
});

app.post('/api/models/register', requireAuth, (req, res) => {
  const { name, backendModel } = req.body;
  if (!name) return res.status(400).json({ error: 'name required' });
  registerModel(name, backendModel);
  res.json({ success: true, model: registry[name] });
});

app.post('/api/tenants/add', requireAuth, (req, res) => {
  const { tenantId } = req.body;
  if (!tenantId) return res.status(400).json({ error: 'tenantId required' });
  tenants.add(tenantId);
  res.json({ success: true, tenants: Array.from(tenants) });
});

// ═══════════════════════════════════════
// HEALTH CHECK (public)
// ═══════════════════════════════════════
app.get('/health', (req, res) => {
  res.json({
    status: 'online',
    version: '0.1.0',
    queue: { pending: pending.length, running },
    models: Object.keys(registry),
    authenticated: !!JWT_SECRET
  });
});

app.listen(PORT, () => {
  console.log(`\n🌊 Strata v0.1.0 running on port ${PORT}\n📦 Models: ${Object.keys(registry).join(', ')}\n🔗 Backend: ${OLLAMA_URL}\n🔒 JWT Auth: ${JWT_SECRET ? 'enabled' : 'disabled (dev mode)'}\n`);
});
