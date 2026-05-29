#!/usr/bin/env node
const fs   = require('fs');
const path = require('path');

// ── Load config for port ──────────────────────────────────────────────────────
function loadConfig() {
  const configPath = path.join(__dirname, 'strata.config.json');
  if (fs.existsSync(configPath)) {
    try { return JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch {}
  }
  return {};
}

const cfg        = loadConfig();
const PORT       = process.env.STRATA_PORT || cfg.port || 11435;
const STRATA_URL = process.env.STRATA_URL  || `http://localhost:${PORT}`;
const BACKEND_URL = process.env.STRATA_BACKEND_URL || cfg.backendUrl || process.env.OLLAMA_URL || 'http://10.0.0.238:11434';
const LOG_FILE   = path.join(__dirname, 'requests.log');
const STRATA_LOG = path.join(__dirname, 'strata.log');

const args    = process.argv.slice(2);
const command = args[0];

// ── HTTP helper ───────────────────────────────────────────────────────────────
async function strataFetch(endpoint, method = 'GET', body = null) {
  try {
    const opts = { method, headers: { 'Content-Type': 'application/json' } };
    if (body) opts.body = JSON.stringify(body);
    const res = await fetch(`${STRATA_URL}${endpoint}`, opts);
    return await res.json();
  } catch {
    console.error(`❌ Could not connect to Strata at ${STRATA_URL}`);
    console.error(`   Is Strata running? Try: sudo systemctl start strata`);
    process.exit(1);
  }
}

// ── Commands ──────────────────────────────────────────────────────────────────
const commands = {

  async status() {
    const data = await strataFetch('/health');
    console.log(`\n🌊 Strata ${data.version}`);
    console.log(`   Status:   ${data.status}`);
    console.log(`   Backend:  ${data.backend} → ${data.backendUrl}`);
    console.log(`   Auth:     ${data.authenticated ? 'JWT enabled' : 'open (dev mode)'}`);
    console.log(`   Queue:    ${data.queue.pending} pending, ${data.queue.running ? 'running' : 'idle'}`);
    console.log(`   Models:   ${data.models.join(', ')}`);
    console.log(`   Prompt:   ${data.systemPrompt}\n`);
  },

  async list() {
    const data = await strataFetch('/api/tags');
    console.log(`\n📦 Registered models:`);
    data.models?.forEach(m => console.log(`   • ${m.name || m}`));
    console.log('');
  },

  async pull() {
    const modelName = args[1];
    if (!modelName) {
      console.log('Usage: strata pull <model>');
      console.log('       strata pull llama3');
      console.log('       strata pull llama3:q4_0');
      return;
    }

    const [model] = modelName.split(':');
    console.log(`\n📥 Pulling ${modelName}...`);
    console.log(`   Backend: ${BACKEND_URL}\n`);

    const http  = require('http');
    const https = require('https');
    const body  = JSON.stringify({ name: modelName, stream: true });
    const url   = new URL(`${BACKEND_URL}/api/pull`);
    const lib   = url.protocol === 'https:' ? https : http;

    return new Promise(resolve => {
      const req = lib.request({
        hostname: url.hostname,
        port:     url.port || (url.protocol === 'https:' ? 443 : 80),
        path:     url.pathname,
        method:   'POST',
        headers:  { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      }, res => {
        if (res.statusCode !== 200) {
          console.log(`❌ Backend returned ${res.statusCode}`);
          resolve(); return;
        }

        let lastStatus = '';

        res.on('data', chunk => {
          chunk.toString().split('\n').filter(Boolean).forEach(line => {
            try {
              const d = JSON.parse(line);

              if (d.total && d.completed) {
                const pct    = Math.round((d.completed / d.total) * 100);
                const filled = Math.round(pct / 5);
                const bar    = `[${'█'.repeat(filled)}${' '.repeat(20 - filled)}] ${pct}%`;
                const mb     = (d.completed / 1024 / 1024).toFixed(1);
                const total  = (d.total / 1024 / 1024).toFixed(1);
                process.stdout.write(`\r   ${d.status}: ${bar} ${mb}/${total} MB   `);
                lastStatus = d.status;
              } else if (d.status && d.status !== lastStatus) {
                if (lastStatus) process.stdout.write('\n');
                process.stdout.write(`   ${d.status}`);
                lastStatus = d.status;
              }

              if (d.status === 'success') {
                console.log('\n');
                console.log(`✅ ${modelName} pulled successfully`);
                console.log(`   Registering with Strata...`);
                strataFetch('/api/models/register', 'POST', { name: model, backendModel: modelName })
                  .then(() => { console.log(`✅ Registered as "${model}" — run: strata list\n`); resolve(); })
                  .catch(() => { console.log(`⚠️  Pull succeeded but Strata not running — register manually: strata register ${model}\n`); resolve(); });
              }
            } catch {}
          });
        });

        res.on('end', resolve);
        res.on('error', err => { console.log(`\n❌ ${err.message}`); resolve(); });
      });

      req.on('error', err => {
        console.log(`❌ Cannot reach backend at ${BACKEND_URL}: ${err.message}`);
        resolve();
      });

      req.write(body);
      req.end();
    });
  },

  async register() {
    const name         = args[1];
    const backendModel = args[2] || name;
    if (!name) { console.error('Usage: strata register <name> [backendModel]'); process.exit(1); }
    const data = await strataFetch('/api/models/register', 'POST', { name, backendModel });
    if (data.success) console.log(`✅ Registered model: ${name} → ${backendModel}`);
    else console.error(`❌ Failed: ${data.error}`);
  },

  async logs() {
    const lines = args[1] ? parseInt(args[1]) : 20;
    if (!fs.existsSync(LOG_FILE)) { console.log('No request logs yet.'); return; }
    const recent = fs.readFileSync(LOG_FILE, 'utf8').trim().split('\n').slice(-lines);
    console.log(`\n📊 Last ${recent.length} requests:\n`);
    recent.forEach(line => {
      try {
        const e    = JSON.parse(line);
        const icon = e.status === 'success' ? '✅' : '❌';
        const time = new Date(e.timestamp).toLocaleTimeString();
        const api  = e.api === 'openai' ? '[OpenAI] ' : '';
        console.log(`${icon} [${time}] ${api}${e.tenant} | ${e.user?.slice(-8)} | ${e.model} | ${e.promptLen}→${e.responseLen} chars | ${e.duration}ms`);
      } catch { console.log(line); }
    });
    console.log('');
  },

  tail() {
    console.log(`\n📋 Tailing Strata log (Ctrl+C to stop):\n`);
    const { exec } = require('child_process');
    const child = exec(`tail -f ${STRATA_LOG}`);
    child.stdout.pipe(process.stdout);
    child.stderr.pipe(process.stderr);
  },

  config() {
    const configPath = path.join(__dirname, 'strata.config.json');
    if (!fs.existsSync(configPath)) {
      console.log('⚠️  No strata.config.json found at', configPath);
      return;
    }
    const c = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    console.log('\n📄 strata.config.json:\n');
    console.log('   Port:    ', c.port        || '(default 11435)');
    console.log('   Backend: ', c.backend     || '(default ollama)');
    console.log('   URL:     ', c.backendUrl  || '(default)');
    console.log('   Model:   ', c.defaultModel|| '(default mixtral)');
    console.log('   Prompt:  ', (c.systemPrompt || '').slice(0, 80) + ((c.systemPrompt?.length > 80) ? '…' : ''));
    console.log('   Log:     ', c.logFile     || '(default)');
    console.log('');
  },

  version() {
    const pkg = require('./package.json');
    console.log(`🌊 Strata v${pkg.version}`);
  },

  help() {
    console.log(`
🌊 Strata CLI

Commands:
  strata status              Show server status
  strata list                List registered models
  strata pull <model>        Pull a model (e.g. strata pull llama3)
                               Supports quant: strata pull llama3:q4_0
  strata register <name>     Register a model with Strata
  strata logs [n]            Show last n request logs (default 20)
  strata tail                Tail the server log live
  strata config              Show current strata.config.json
  strata version             Show version
  strata help                Show this help
    `);
  }
};

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  if (!command || command === 'help') return commands.help();
  if (commands[command]) await commands[command]();
  else { console.error(`❌ Unknown command: ${command}`); commands.help(); process.exit(1); }
}

main().catch(err => { console.error('❌ Error:', err.message); process.exit(1); });
