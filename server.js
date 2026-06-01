const express = require('express');
const cors = require('cors');
const jwt = require('jsonwebtoken');
const fs = require('fs');
require('dotenv').config();

const app = express();
app.use(cors());
app.use(express.json({ limit: '50mb' }));

// ═══════════════════════════════════════
// CONFIG — strata.config.json → .env → defaults
// ═══════════════════════════════════════
function loadConfig() {
  const defaults = {
    port: 11435,
    backend: 'ollama',
    backendUrl: 'http://10.0.0.238:11434',
    defaultModel: 'mixtral',
    systemPrompt: 'You are a helpful AI assistant.',
    jwtSecret: null,
    logFile: '/home/tristenadmin/Strata/requests.log',
    webhookUrl: null,
  };

  let fileConfig = {};
  const configPath = `${process.cwd()}/strata.config.json`;
  if (fs.existsSync(configPath)) {
    try {
      fileConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
      console.log('✅ Loaded strata.config.json');
    } catch (e) {
      console.warn('⚠️  Could not parse strata.config.json:', e.message);
    }
  }

  const envConfig = {};
  if (process.env.STRATA_PORT)          envConfig.port         = parseInt(process.env.STRATA_PORT);
  if (process.env.OLLAMA_URL)           envConfig.backendUrl   = process.env.OLLAMA_URL; // legacy compat
  if (process.env.STRATA_BACKEND)       envConfig.backend      = process.env.STRATA_BACKEND;
  if (process.env.STRATA_BACKEND_URL)   envConfig.backendUrl   = process.env.STRATA_BACKEND_URL;
  if (process.env.STRATA_SYSTEM_PROMPT) envConfig.systemPrompt = process.env.STRATA_SYSTEM_PROMPT;
  if (process.env.JWT_ACCESS_SECRET)    envConfig.jwtSecret    = process.env.JWT_ACCESS_SECRET;
  if (process.env.STRATA_LOG)           envConfig.logFile      = process.env.STRATA_LOG;
  if (process.env.STRATA_WEBHOOK_URL)   envConfig.webhookUrl   = process.env.STRATA_WEBHOOK_URL;

  return { ...defaults, ...fileConfig, ...envConfig };
}

const config = loadConfig();

const PORT             = config.port;
const JWT_SECRET       = config.jwtSecret;
const BASE_SYSTEM_PROMPT = config.systemPrompt;

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
// REQUEST LOGGER
// ═══════════════════════════════════════
function logRequest(entry) {
  const line = JSON.stringify({ timestamp: new Date().toISOString(), ...entry });
  console.log(`📊 ${entry.status === 'success' ? '✅' : '❌'} [${entry.tenant}] ${entry.user} → ${entry.model} | ${entry.promptLen} chars | ${entry.responseLen} chars | ${entry.duration}ms`);
  fs.appendFile(config.logFile, line + '\n', err => { if (err) console.error('Log write failed:', err.message); });
}

// ═══════════════════════════════════════
// WEBHOOK NOTIFICATIONS
// Fires a POST to config.webhookUrl on key events
// Set STRATA_WEBHOOK_URL in .env or strata.config.json
// ═══════════════════════════════════════
async function fireWebhook(event, data) {
  if (!config.webhookUrl) return;
  try {
    await fetch(config.webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      signal: AbortSignal.timeout(5000),
      body: JSON.stringify({
        event,
        timestamp: new Date().toISOString(),
        ...data,
      }),
    });
  } catch (err) {
    console.warn(`⚠️  Webhook failed (${event}):`, err.message);
  }
}
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
  try { resolve(await fn()); }
  catch (err) { reject(err); }
  finally { running = false; processQueue(); }
}

// ═══════════════════════════════════════
// RATE LIMITER — 15 requests per 5 minutes per user
// ═══════════════════════════════════════
const requestLog = {};
const RATE_WINDOW_MS = 5 * 60 * 1000;
const RATE_LIMIT = 15;

function checkRateLimit(userId) {
  const now = Date.now();
  if (!requestLog[userId]) requestLog[userId] = [];
  requestLog[userId] = requestLog[userId].filter(t => now - t < RATE_WINDOW_MS);
  if (requestLog[userId].length >= RATE_LIMIT) {
    const retryAfter = Math.ceil((RATE_WINDOW_MS - (now - requestLog[userId][0])) / 1000);
    fireWebhook('rate_limit_hit', { userId, retryAfter, requests: requestLog[userId].length });
    return { limited: true, retryAfter };
  }
  requestLog[userId].push(now);
  return { limited: false };
}

setInterval(() => {
  const now = Date.now();
  Object.keys(requestLog).forEach(key => {
    requestLog[key] = requestLog[key].filter(t => now - t < RATE_WINDOW_MS);
    if (requestLog[key].length === 0) delete requestLog[key];
  });
}, 10 * 60 * 1000);

// ═══════════════════════════════════════
// TENANT REGISTRY
// ═══════════════════════════════════════
const tenants = new Set(['*']);
function isAuthorized(tenantId) { return tenants.has('*') || tenants.has(tenantId); }

// ═══════════════════════════════════════
// BACKEND ROUTER
// Supports: ollama | llama.cpp | vllm | openai
// ═══════════════════════════════════════
async function routeToBackend(model, messages, stream = false) {
  const backendModel = registry[model]?.backendModel || model;
  const { backend, backendUrl } = config;

  switch (backend) {

    case 'ollama': {
      const res = await fetch(`${backendUrl}/api/chat`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        signal: AbortSignal.timeout(240000),
        body: JSON.stringify({ model: backendModel, messages, stream }),
      });
      if (!res.ok) throw new Error(`Ollama error ${res.status}: ${await res.text()}`);
      if (stream) return res; // return raw response for streaming
      const data = await res.json();
      return {
        content: data.message?.content ?? '',
        model: data.model ?? model,
        promptTokens: data.prompt_eval_count ?? 0,
        completionTokens: data.eval_count ?? 0,
      };
    }

    case 'llama.cpp': {
      if (stream) {
        const prompt = messages.map(m => `${m.role}: ${m.content}`).join('\n') + '\nassistant:';
        const res = await fetch(`${backendUrl}/completion`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          signal: AbortSignal.timeout(240000),
          body: JSON.stringify({ prompt, temperature: 0.7, stop: ['\nuser:'], stream: true }),
        });
        if (!res.ok) throw new Error(`llama.cpp error ${res.status}`);
        return res;
      }
      const prompt = messages.map(m => `${m.role}: ${m.content}`).join('\n') + '\nassistant:';
      const res = await fetch(`${backendUrl}/completion`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        signal: AbortSignal.timeout(240000),
        body: JSON.stringify({ prompt, temperature: 0.7, stop: ['\nuser:'] }),
      });
      if (!res.ok) throw new Error(`llama.cpp error ${res.status}: ${await res.text()}`);
      const data = await res.json();
      return { content: data.content ?? '', model, promptTokens: data.tokens_evaluated ?? 0, completionTokens: data.tokens_predicted ?? 0 };
    }

    case 'vllm':
    case 'openai': {
      const headers = { 'Content-Type': 'application/json' };
      if (process.env.OPENAI_API_KEY) headers['Authorization'] = `Bearer ${process.env.OPENAI_API_KEY}`;
      const res = await fetch(`${backendUrl}/v1/chat/completions`, {
        method: 'POST',
        headers,
        signal: AbortSignal.timeout(240000),
        body: JSON.stringify({ model: backendModel, messages, stream }),
      });
      if (!res.ok) throw new Error(`${backend} error ${res.status}: ${await res.text()}`);
      if (stream) return res;
      const data = await res.json();
      return {
        content: data.choices?.[0]?.message?.content ?? '',
        model: data.model ?? model,
        promptTokens: data.usage?.prompt_tokens ?? 0,
        completionTokens: data.usage?.completion_tokens ?? 0,
      };
    }

    default:
      throw new Error(`Unknown backend: "${backend}". Valid: ollama, llama.cpp, vllm, openai`);
  }
}

// Helper: prepend system prompt if caller didn't supply one
function withSystemPrompt(messages) {
  if (messages.some(m => m.role === 'system')) return messages;
  return [{ role: 'system', content: BASE_SYSTEM_PROMPT }, ...messages];
}

// Helper: extract token from a backend stream chunk
function extractStreamToken(line, backend) {
  try {
    if (backend === 'ollama') {
      const d = JSON.parse(line);
      return { token: d.message?.content || '', done: !!d.done };
    }
    if (backend === 'llama.cpp') {
      const d = JSON.parse(line);
      return { token: d.content || '', done: !!d.stop };
    }
    // vllm / openai SSE
    const clean = line.replace(/^data: /, '').trim();
    if (clean === '[DONE]') return { token: '', done: true };
    const d = JSON.parse(clean);
      return { token: d.choices?.[0]?.delta?.content || '', done: !!d.choices?.[0]?.finish_reason };
  } catch { return null; }
}

// ═══════════════════════════════════════
// ORIGINAL INFERENCE ENDPOINT (backward compat)
// ═══════════════════════════════════════
app.post('/api/generate', requireAuth, async (req, res) => {
  const tenantId = req.user?.businessId || req.headers['x-tenant-id'] || 'default';
  if (!isAuthorized(tenantId)) return res.status(401).json({ error: 'Unauthorized tenant' });

  const { model, prompt, options } = req.body;
  const entry = registry[model];
  if (!entry) return res.status(404).json({ error: `Model not found: ${model}` });

  const startTime = Date.now();
  console.log(`🌊 /api/generate — model: ${model}, tenant: ${tenantId}, prompt: ${prompt?.length} chars`);

  try {
    const result = await enqueue(async () => {
      const fullPrompt = prompt.includes(BASE_SYSTEM_PROMPT) ? prompt : `${BASE_SYSTEM_PROMPT}\n\n${prompt}`;
      const response = await fetch(`${config.backendUrl}/api/generate`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        signal: AbortSignal.timeout(240000),
        body: JSON.stringify({ model: entry.backendModel, prompt: fullPrompt, stream: false, options: options || { temperature: 0.1, repeat_penalty: 1.1 } })
      });
      if (!response.ok) throw new Error(`Backend error: ${response.status}`);
      return await response.json();
    });
    logRequest({ status: 'success', tenant: tenantId, user: req.user?.userId || req.ip, model, promptLen: prompt?.length || 0, responseLen: result.response?.length || 0, duration: Date.now() - startTime });
    res.json(result);
  } catch (err) {
    logRequest({ status: 'error', tenant: tenantId, user: req.user?.userId || req.ip, model, promptLen: prompt?.length || 0, responseLen: 0, duration: Date.now() - startTime, error: err.message });
    console.error(`❌ /api/generate failed:`, err.message);
    fireWebhook('model_error', { model, error: err.message, tenant: tenantId });
    res.status(500).json({ error: err.message });
  }
});

// ═══════════════════════════════════════
// STREAMING INFERENCE ENDPOINT (backward compat)
// ═══════════════════════════════════════
app.post('/api/generate/stream', requireAuth, async (req, res) => {
  const tenantId = req.user?.businessId || req.headers['x-tenant-id'] || 'default';
  const { model, prompt, options } = req.body;
  const entry = registry[model];
  if (!entry) return res.status(404).json({ error: `Model not found: ${model}` });

  const userId = req.user?.userId || req.ip;
  const rateCheck = checkRateLimit(userId);
  if (rateCheck.limited) return res.status(429).json({ error: `Rate limit exceeded. Try again in ${rateCheck.retryAfter} seconds.` });

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  const startTime = Date.now();
  let totalResponse = '';

  try {
    const fullPrompt = prompt.includes(BASE_SYSTEM_PROMPT) ? prompt : `${BASE_SYSTEM_PROMPT}\n\n${prompt}`;
    const response = await fetch(`${config.backendUrl}/api/generate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      signal: AbortSignal.timeout(240000),
      body: JSON.stringify({ model: entry.backendModel, prompt: fullPrompt, stream: true, options: options || { temperature: 0.1, repeat_penalty: 1.1 } })
    });

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const lines = decoder.decode(value).split('\n').filter(l => l.trim());
      for (const line of lines) {
        try {
          const data = JSON.parse(line);
          if (data.response) { totalResponse += data.response; res.write(`data: ${JSON.stringify({ token: data.response })}\n\n`); }
          if (data.done) {
            logRequest({ status: 'success', tenant: tenantId, user: userId, model, promptLen: prompt?.length || 0, responseLen: totalResponse.length, duration: Date.now() - startTime, streaming: true });
            res.write(`data: ${JSON.stringify({ done: true, total: totalResponse })}\n\n`);
            res.end(); return;
          }
        } catch {}
      }
    }
  } catch (err) {
    console.error(`❌ Stream failed:`, err.message);
    res.write(`data: ${JSON.stringify({ error: err.message })}\n\n`);
    res.end();
  }
});

// ═══════════════════════════════════════
// OPENAI-COMPATIBLE API
// Any OpenAI client: point base_url at http://YOUR_IP:11435/v1
// ═══════════════════════════════════════

app.get('/v1/models', requireAuth, (req, res) => {
  res.json({
    object: 'list',
    data: Object.values(registry).map(m => ({
      id: m.name, object: 'model', created: Math.floor(Date.now() / 1000), owned_by: 'strata',
    })),
  });
});

app.post('/v1/chat/completions', requireAuth, async (req, res) => {
  const { model, messages = [], stream = false } = req.body;

  if (!model)                                    return res.status(400).json({ error: { message: 'model is required', type: 'invalid_request_error' } });
  if (!Array.isArray(messages) || !messages.length) return res.status(400).json({ error: { message: 'messages array is required', type: 'invalid_request_error' } });
  if (!registry[model])                          return res.status(404).json({ error: { message: `Model not found: ${model}`, type: 'invalid_request_error' } });

  const tenantId    = req.user?.businessId || req.headers['x-tenant-id'] || 'default';
  const userId      = req.user?.userId || req.ip;
  const fullMessages = withSystemPrompt(messages);
  const requestId   = `chatcmpl-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const created     = Math.floor(Date.now() / 1000);
  const startTime   = Date.now();

  console.log(`🌊 /v1/chat/completions — model: ${model}, stream: ${stream}, backend: ${config.backend}`);

  // ── Streaming ────────────────────────────────────────────────────────────
  if (stream) {
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    res.flushHeaders();

    try {
      const backendRes = await routeToBackend(model, fullMessages, true);
      const reader  = backendRes.body.getReader();
      const decoder = new TextDecoder();
      let totalLen  = 0;

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const lines = decoder.decode(value).split('\n').filter(Boolean);
        for (const line of lines) {
          const parsed = extractStreamToken(line, config.backend);
          if (!parsed) continue;
          if (parsed.token) {
            totalLen += parsed.token.length;
            res.write(`data: ${JSON.stringify({ id: requestId, object: 'chat.completion.chunk', created, model, choices: [{ index: 0, delta: { content: parsed.token }, finish_reason: null }] })}\n\n`);
          }
          if (parsed.done) {
            logRequest({ status: 'success', tenant: tenantId, user: userId, model, promptLen: JSON.stringify(messages).length, responseLen: totalLen, duration: Date.now() - startTime, streaming: true, api: 'openai' });
          }
        }
      }
      res.write(`data: ${JSON.stringify({ id: requestId, object: 'chat.completion.chunk', created, model, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] })}\n\n`);
      res.write('data: [DONE]\n\n');
      res.end();
    } catch (err) {
      console.error('❌ OpenAI stream failed:', err.message);
      res.write(`data: ${JSON.stringify({ error: err.message })}\n\n`);
      res.end();
    }
    return;
  }

  // ── Non-streaming ────────────────────────────────────────────────────────
  try {
    const result = await enqueue(() => routeToBackend(model, fullMessages, false));
    logRequest({ status: 'success', tenant: tenantId, user: userId, model, promptLen: JSON.stringify(messages).length, responseLen: result.content.length, duration: Date.now() - startTime, api: 'openai' });
    res.json({
      id: requestId, object: 'chat.completion', created, model: result.model,
      choices: [{ index: 0, message: { role: 'assistant', content: result.content }, finish_reason: 'stop' }],
      usage: { prompt_tokens: result.promptTokens, completion_tokens: result.completionTokens, total_tokens: result.promptTokens + result.completionTokens },
    });
  } catch (err) {
    console.error('❌ OpenAI completions failed:', err.message);
    logRequest({ status: 'error', tenant: tenantId, user: userId, model, promptLen: JSON.stringify(messages).length, responseLen: 0, duration: Date.now() - startTime, error: err.message, api: 'openai' });
    fireWebhook('model_error', { model, error: err.message, tenant: tenantId, api: 'openai' });
    res.status(502).json({ error: { message: err.message, type: 'backend_error', code: 502 } });
  }
});

// ═══════════════════════════════════════
// MODEL MANAGEMENT
// ═══════════════════════════════════════
app.get('/api/tags', (req, res) => {
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
    version: '0.2.0',
    backend: config.backend,
    backendUrl: config.backendUrl,
    queue: { pending: pending.length, running },
    models: Object.keys(registry),
    authenticated: !!JWT_SECRET,
    systemPrompt: BASE_SYSTEM_PROMPT.slice(0, 80) + (BASE_SYSTEM_PROMPT.length > 80 ? '…' : ''),
  });
});

// ═══════════════════════════════════════
// STRATA WEB UI — served at /ui
// ═══════════════════════════════════════
const uiAlerts = [];

app.get('/ui', (req, res) => {
  res.setHeader('Content-Type', 'text/html');
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Strata Gateway</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f172a; color: #e2e8f0; min-height: 100vh; }
  .header { background: rgba(30,41,59,0.9); border-bottom: 1px solid rgba(59,130,246,0.2); padding: 16px 32px; display: flex; align-items: center; justify-content: space-between; }
  .logo { font-size: 20px; font-weight: 700; color: #3b82f6; display: flex; align-items: center; gap: 10px; }
  .badge { padding: 3px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; }
  .badge.online { background: rgba(34,197,94,0.15); color: #22c55e; }
  .badge.offline { background: rgba(239,68,68,0.15); color: #ef4444; }
  .version { color: #475569; font-size: 13px; }
  .main { padding: 32px; max-width: 1200px; margin: 0 auto; }
  .tabs { display: flex; gap: 8px; margin-bottom: 24px; }
  .tab { padding: 8px 18px; border-radius: 8px; border: none; cursor: pointer; font-size: 14px; font-weight: 500; transition: all 0.2s; background: transparent; color: #64748b; }
  .tab.active { background: rgba(59,130,246,0.2); color: #3b82f6; }
  .tab:hover:not(.active) { background: rgba(255,255,255,0.05); color: #94a3b8; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; margin-bottom: 28px; }
  .card { background: rgba(30,41,59,0.8); border: 1px solid rgba(59,130,246,0.15); border-radius: 12px; padding: 20px; }
  .card-label { font-size: 12px; color: #64748b; margin-bottom: 6px; text-transform: uppercase; letter-spacing: 0.05em; }
  .card-value { font-size: 30px; font-weight: 700; color: #3b82f6; }
  .card-sub { font-size: 12px; color: #475569; margin-top: 4px; }
  .section { background: rgba(30,41,59,0.8); border: 1px solid rgba(59,130,246,0.15); border-radius: 12px; padding: 24px; margin-bottom: 20px; }
  .section-title { font-size: 15px; font-weight: 600; color: #e2e8f0; margin-bottom: 16px; padding-bottom: 12px; border-bottom: 1px solid rgba(59,130,246,0.1); }
  .row { display: flex; align-items: center; justify-content: space-between; padding: 10px 0; border-bottom: 1px solid rgba(59,130,246,0.06); font-size: 14px; }
  .row:last-child { border-bottom: none; }
  .row-label { color: #64748b; }
  .row-value { color: #94a3b8; }
  .pill { background: rgba(59,130,246,0.15); color: #3b82f6; padding: 3px 10px; border-radius: 999px; font-size: 12px; font-weight: 500; }
  .log-header { display: grid; grid-template-columns: 70px 1fr 100px 80px 80px; gap: 12px; padding: 6px 12px; font-size: 11px; color: #475569; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 4px; }
  .log-row { display: grid; grid-template-columns: 70px 1fr 100px 80px 80px; gap: 12px; padding: 9px 12px; border-radius: 6px; margin-bottom: 3px; font-size: 13px; color: #94a3b8; align-items: center; }
  .log-row.ok { background: rgba(34,197,94,0.05); }
  .log-row.err { background: rgba(239,68,68,0.05); }
  .status-ok { color: #22c55e; }
  .status-err { color: #ef4444; }
  .model-row { display: flex; align-items: center; justify-content: space-between; padding: 12px 0; border-bottom: 1px solid rgba(59,130,246,0.06); }
  .model-row:last-child { border-bottom: none; }
  .model-name { color: #e2e8f0; font-weight: 500; font-size: 15px; }
  .alert-row { padding: 12px 16px; border-radius: 8px; margin-bottom: 8px; background: rgba(245,158,11,0.08); border: 1px solid rgba(245,158,11,0.2); font-size: 13px; color: #fbbf24; }
  .alert-time { float: right; color: #64748b; font-size: 12px; }
  .empty { color: #475569; padding: 24px 0; text-align: center; }
  .refresh-btn { background: rgba(59,130,246,0.15); border: 1px solid rgba(59,130,246,0.3); border-radius: 8px; color: #3b82f6; padding: 8px 16px; cursor: pointer; font-size: 13px; }
  .refresh-btn:hover { background: rgba(59,130,246,0.25); }
  .last-updated { text-align: right; font-size: 12px; color: #475569; margin-top: 8px; }
  .alert-count { background: rgba(239,68,68,0.3); color: #ef4444; border-radius: 999px; padding: 1px 6px; font-size: 11px; margin-left: 6px; }
  #loading { text-align: center; padding: 60px; color: #475569; font-size: 16px; }
</style>
</head>
<body>
<div class="header">
  <div class="logo">
    🌊 Strata
    <span class="badge offline" id="status-badge">Connecting...</span>
    <span class="version" id="version-badge"></span>
  </div>
  <button class="refresh-btn" onclick="fetchAll()">↻ Refresh</button>
</div>
<div class="main">
  <div class="tabs">
    <button class="tab active" onclick="switchTab('overview', this)">Overview</button>
    <button class="tab" onclick="switchTab('models', this)">Models</button>
    <button class="tab" onclick="switchTab('logs', this)">Logs</button>
    <button class="tab" onclick="switchTab('alerts', this)">Alerts <span id="alert-count"></span></button>
  </div>
  <div id="loading">Loading Strata data...</div>
  <div id="tab-overview" style="display:none">
    <div class="grid">
      <div class="card"><div class="card-label">Total Requests</div><div class="card-value" id="stat-total">—</div><div class="card-sub">Last 100 logged</div></div>
      <div class="card"><div class="card-label">Success Rate</div><div class="card-value" id="stat-success">—</div><div class="card-sub" id="stat-success-sub"></div></div>
      <div class="card"><div class="card-label">Avg Response</div><div class="card-value" id="stat-avg">—</div><div class="card-sub">Across all requests</div></div>
      <div class="card"><div class="card-label">Queue</div><div class="card-value" id="stat-queue">—</div><div class="card-sub" id="stat-queue-sub"></div></div>
    </div>
    <div class="section">
      <div class="section-title">Gateway Status</div>
      <div class="row"><span class="row-label">Backend</span><span id="info-backend" class="pill">—</span></div>
      <div class="row"><span class="row-label">Backend URL</span><span class="row-value" id="info-url">—</span></div>
      <div class="row"><span class="row-label">Auth</span><span class="row-value" id="info-auth">—</span></div>
      <div class="row"><span class="row-label">System Prompt</span><span class="row-value" id="info-prompt" style="max-width:500px;text-align:right;font-size:12px">—</span></div>
    </div>
    <div class="last-updated" id="last-updated"></div>
  </div>
  <div id="tab-models" style="display:none">
    <div class="section">
      <div class="section-title">Registered Models</div>
      <div id="models-list"><div class="empty">No models registered.</div></div>
    </div>
  </div>
  <div id="tab-logs" style="display:none">
    <div class="section">
      <div class="section-title">Request Logs <span id="log-count" style="font-size:13px;color:#64748b;font-weight:400"></span></div>
      <div class="log-header"><span>Status</span><span>User → Model</span><span>API</span><span>Size</span><span>Time</span></div>
      <div id="logs-list"><div class="empty">No logs yet.</div></div>
    </div>
  </div>
  <div id="tab-alerts" style="display:none">
    <div class="section">
      <div class="section-title">Strata Alerts <span id="alerts-count-label" style="font-size:13px;color:#64748b;font-weight:400"></span></div>
      <div id="alerts-list"><div class="empty">No alerts yet.</div></div>
    </div>
  </div>
</div>
<script>
let state = { status: null, logs: [], alerts: [] };
function switchTab(name, btn) {
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  btn.classList.add('active');
  ['overview','models','logs','alerts'].forEach(t => {
    document.getElementById('tab-' + t).style.display = t === name ? 'block' : 'none';
  });
}
async function fetchAll() {
  try {
    const [s, l, a] = await Promise.all([
      fetch('/health').then(r => r.json()),
      fetch('/api/logs?n=100').then(r => r.json()),
      fetch('/api/alerts').then(r => r.json()),
    ]);
    state.status = s; state.logs = l.logs || []; state.alerts = a.alerts || [];
    render();
  } catch(e) {
    document.getElementById('status-badge').textContent = 'Offline';
    document.getElementById('status-badge').className = 'badge offline';
  }
}
function render() {
  const { status, logs, alerts } = state;
  document.getElementById('loading').style.display = 'none';
  document.getElementById('tab-overview').style.display = 'block';
  const online = status?.status === 'online';
  const badge = document.getElementById('status-badge');
  badge.textContent = online ? 'Online' : 'Offline';
  badge.className = 'badge ' + (online ? 'online' : 'offline');
  document.getElementById('version-badge').textContent = status?.version ? 'v' + status.version : '';
  const ok = logs.filter(l => l.status === 'success');
  const err = logs.filter(l => l.status === 'error');
  const avg = logs.length ? Math.round(logs.reduce((a,l) => a+(l.duration||0),0)/logs.length) : 0;
  document.getElementById('stat-total').textContent = logs.length;
  document.getElementById('stat-success').textContent = logs.length ? Math.round(ok.length/logs.length*100)+'%' : '—';
  document.getElementById('stat-success-sub').textContent = ok.length + ' ok / ' + err.length + ' errors';
  document.getElementById('stat-avg').textContent = avg ? avg+'ms' : '—';
  document.getElementById('stat-queue').textContent = status?.queue?.pending ?? '—';
  document.getElementById('stat-queue-sub').textContent = status?.queue?.running ? 'Running' : 'Idle';
  document.getElementById('info-backend').textContent = status?.backend || '—';
  document.getElementById('info-url').textContent = status?.backendUrl || '—';
  document.getElementById('info-auth').textContent = status?.authenticated ? 'JWT Enabled' : 'Open';
  document.getElementById('info-prompt').textContent = status?.systemPrompt || '—';
  document.getElementById('last-updated').textContent = 'Last updated: ' + new Date().toLocaleTimeString();
  const models = status?.models || [];
  document.getElementById('models-list').innerHTML = models.length
    ? models.map(m => '<div class="model-row"><span class="model-name">'+m+'</span><span class="pill">active</span></div>').join('')
    : '<div class="empty">No models registered.</div>';
  document.getElementById('log-count').textContent = '(' + logs.length + ' entries)';
  document.getElementById('logs-list').innerHTML = logs.slice(0,50).map(l =>
    '<div class="log-row '+(l.status==='success'?'ok':'err')+'">' +
    '<span class="'+(l.status==='success'?'status-ok':'status-err')+'">'+(l.status==='success'?'✅':'❌')+' '+l.status+'</span>' +
    '<span style="color:#e2e8f0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'+(l.user||'').slice(-8)+' → <strong>'+l.model+'</strong></span>' +
    '<span>'+(l.api==='openai'?'🟢 OpenAI':'⚪ Native')+'</span>' +
    '<span>'+(l.responseLen ? Math.round(l.responseLen/1024*10)/10+'k' : '—')+'</span>' +
    '<span style="color:'+(l.duration>10000?'#f59e0b':'#94a3b8')+'">'+l.duration+'ms</span>' +
    '</div>'
  ).join('') || '<div class="empty">No request logs yet.</div>';
  const ac = document.getElementById('alert-count');
  ac.textContent = alerts.length > 0 ? alerts.length : '';
  ac.className = alerts.length > 0 ? 'alert-count' : '';
  document.getElementById('alerts-count-label').textContent = '(' + alerts.length + ' received)';
  document.getElementById('alerts-list').innerHTML = alerts.map(a =>
    '<div class="alert-row">' +
    '<span class="alert-time">'+new Date(a.receivedAt).toLocaleTimeString()+'</span>' +
    '<strong>'+a.event+'</strong>' +
    (a.userId ? '<span style="margin-left:12px;color:#94a3b8">User: '+a.userId+'</span>' : '') +
    (a.model  ? '<span style="margin-left:12px;color:#94a3b8">Model: '+a.model+'</span>' : '') +
    (a.error  ? '<span style="margin-left:12px;color:#ef4444">'+a.error+'</span>' : '') +
    '</div>'
  ).join('') || '<div class="empty">No alerts yet.</div>';
}
fetchAll();
setInterval(fetchAll, 30000);
</script>
</body>
</html>`);
});

// Public endpoints for the UI (no auth — UI reads these directly)
app.get('/api/logs', (req, res) => {
  const n = parseInt(req.query.n) || 50;
  try {
    if (!fs.existsSync(config.logFile)) return res.json({ logs: [] });
    const lines = fs.readFileSync(config.logFile, 'utf8').trim().split('\n').filter(Boolean);
    const recent = lines.slice(-n).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean).reverse();
    res.json({ logs: recent });
  } catch (e) { res.json({ logs: [] }); }
});

app.get('/api/alerts', (req, res) => res.json({ alerts: uiAlerts }));

app.post('/api/ui/webhook', (req, res) => {
  const alert = { ...req.body, receivedAt: new Date().toISOString() };
  uiAlerts.unshift(alert);
  if (uiAlerts.length > 100) uiAlerts.pop();
  res.json({ ok: true });
});

app.listen(PORT, () => {
  console.log(`
🌊 Strata v0.2.0 running on port ${PORT}
📦 Models:     ${Object.keys(registry).join(', ')}
🔗 Backend:    ${config.backend} → ${config.backendUrl}
🔒 JWT Auth:   ${JWT_SECRET ? 'enabled' : 'disabled (dev mode)'}
🤖 Prompt:     ${BASE_SYSTEM_PROMPT.slice(0, 60)}…
🟢 OpenAI API: http://localhost:${PORT}/v1
🖥️  Web UI:    http://localhost:${PORT}/ui
`);
});
