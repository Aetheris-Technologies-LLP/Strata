#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const STRATA_URL = process.env.STRATA_URL || 'http://localhost:11435';
const LOG_FILE = path.join(__dirname, 'requests.log');
const STRATA_LOG = path.join(__dirname, 'strata.log');

const args = process.argv.slice(2);
const command = args[0];

async function strataFetch(endpoint, method = 'GET', body = null) {
  try {
    const opts = {
      method,
      headers: { 'Content-Type': 'application/json' }
    };
    if (body) opts.body = JSON.stringify(body);
    const res = await fetch(`${STRATA_URL}${endpoint}`, opts);
    return await res.json();
  } catch (err) {
    console.error(`❌ Could not connect to Strata at ${STRATA_URL}`);
    console.error(`   Is Strata running? Try: strata start`);
    process.exit(1);
  }
}

const commands = {

  async status() {
    const data = await strataFetch('/health');
    console.log(`\n🌊 Strata ${data.version}`);
    console.log(`   Status:    ${data.status}`);
    console.log(`   Auth:      ${data.authenticated ? 'JWT enabled' : 'open (dev mode)'}`);
    console.log(`   Queue:     ${data.queue.pending} pending, ${data.queue.running ? 'running' : 'idle'}`);
    console.log(`   Models:    ${data.models.join(', ')}\n`);
  },

  async list() {
    const data = await strataFetch('/api/tags');
    console.log(`\n📦 Registered models:`);
    data.models?.forEach(m => console.log(`   • ${m.name || m}`));
    console.log('');
  },

  async register() {
    const name = args[1];
    const backendModel = args[2] || name;
    if (!name) {
      console.error('Usage: strata register <name> [backendModel]');
      process.exit(1);
    }
    const data = await strataFetch('/api/models/register', 'POST', { name, backendModel });
    if (data.success) {
      console.log(`✅ Registered model: ${name} → ${backendModel}`);
    } else {
      console.error(`❌ Failed: ${data.error}`);
    }
  },

  async logs() {
    const lines = args[1] ? parseInt(args[1]) : 20;
    if (!fs.existsSync(LOG_FILE)) {
      console.log('No request logs yet.');
      return;
    }
    const content = fs.readFileSync(LOG_FILE, 'utf8').trim().split('\n');
    const recent = content.slice(-lines);
    console.log(`\n📊 Last ${recent.length} requests:\n`);
    recent.forEach(line => {
      try {
        const entry = JSON.parse(line);
        const icon = entry.status === 'success' ? '✅' : '❌';
        const time = new Date(entry.timestamp).toLocaleTimeString();
        console.log(`${icon} [${time}] ${entry.tenant} | ${entry.user?.slice(-8)} | ${entry.model} | ${entry.promptLen}→${entry.responseLen} chars | ${entry.duration}ms`);
      } catch {
        console.log(line);
      }
    });
    console.log('');
  },

  async tail() {
    console.log(`\n📋 Tailing Strata log (Ctrl+C to stop):\n`);
    const { exec } = require('child_process');
    const child = exec(`tail -f ${STRATA_LOG}`);
    child.stdout.pipe(process.stdout);
    child.stderr.pipe(process.stderr);
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
  strata register <name>     Register a model
  strata logs [n]            Show last n request logs (default 20)
  strata tail                Tail the server log live
  strata version             Show version
  strata help                Show this help
    `);
  }
};

async function main() {
  if (!command || command === 'help') return commands.help();
  if (commands[command]) {
    await commands[command]();
  } else {
    console.error(`❌ Unknown command: ${command}`);
    commands.help();
    process.exit(1);
  }
}

main().catch(err => {
  console.error('❌ Error:', err.message);
  process.exit(1);
});
