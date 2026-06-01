#!/usr/bin/env node
// ═══════════════════════════════════════
// Strata GPU Agent
// Run this on your GPU machine to expose stats to Strata
// Usage: node gpu-agent.js
// Default port: 11436
// ═══════════════════════════════════════
const http    = require('http');
const { exec } = require('child_process');

const PORT = process.env.GPU_AGENT_PORT || 11436;
const TOKEN = process.env.GPU_AGENT_TOKEN || null; // optional shared secret

function queryNvidia() {
  return new Promise((resolve) => {
    exec(
      'nvidia-smi --query-gpu=index,name,temperature.gpu,memory.used,memory.total,utilization.gpu,power.draw,power.limit --format=csv,noheader,nounits',
      (err, stdout) => {
        if (err || !stdout.trim()) return resolve([]);
        const gpus = stdout.trim().split('\n').map(line => {
          const [index, name, temp, memUsed, memTotal, util, powerDraw, powerLimit] = line.split(',').map(s => s.trim());
          return {
            index:      parseInt(index),
            name,
            temp:       parseInt(temp),
            memUsed:    parseInt(memUsed),
            memTotal:   parseInt(memTotal),
            memPct:     Math.round(parseInt(memUsed) / parseInt(memTotal) * 100),
            util:       parseInt(util),
            powerDraw:  parseFloat(powerDraw),
            powerLimit: parseFloat(powerLimit),
          };
        });
        resolve(gpus);
      }
    );
  });
}

function queryAMD() {
  return new Promise((resolve) => {
    exec('rocm-smi --showtemp --showmeminfo vram --showuse --json', (err, stdout) => {
      if (err || !stdout.trim()) return resolve([]);
      try {
        const data = JSON.parse(stdout);
        const gpus = Object.entries(data).map(([key, val], i) => ({
          index:   i,
          name:    val['Card series'] || 'AMD GPU',
          temp:    parseInt(val['Temperature (Sensor edge) (C)']) || 0,
          memUsed: parseInt(val['VRAM Total Used Memory (B)']) / 1024 / 1024 || 0,
          memTotal:parseInt(val['VRAM Total Memory (B)']) / 1024 / 1024 || 0,
          memPct:  Math.round(parseInt(val['VRAM Total Used Memory (B)']) / parseInt(val['VRAM Total Memory (B)']) * 100) || 0,
          util:    parseInt(val['GPU use (%)']) || 0,
          powerDraw: 0, powerLimit: 0,
        }));
        resolve(gpus);
      } catch { resolve([]); }
    });
  });
}

const server = http.createServer(async (req, res) => {
  // Optional token check
  if (TOKEN) {
    const auth = req.headers['x-gpu-token'];
    if (auth !== TOKEN) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Unauthorized' }));
      return;
    }
  }

  if (req.url === '/gpu' || req.url === '/') {
    let gpus = await queryNvidia();
    if (!gpus.length) gpus = await queryAMD();

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      gpus,
      timestamp: new Date().toISOString(),
      source: gpus.length ? (gpus[0].powerLimit ? 'nvidia' : 'amd') : 'none',
    }));
    return;
  }

  res.writeHead(404);
  res.end();
});

server.listen(PORT, () => {
  console.log(`\n🖥️  Strata GPU Agent running on port ${PORT}`);
  console.log(`   Endpoint: http://YOUR_IP:${PORT}/gpu`);
  console.log(`   Token:    ${TOKEN ? 'enabled' : 'disabled (set GPU_AGENT_TOKEN to secure)'}\n`);
});
