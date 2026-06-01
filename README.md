# 🌊 Strata
**Strata** is an open-source AI model gateway — a backend-agnostic runtime that sits between your application and your model backend. Drop-in OpenAI-compatible API, JWT auth, multi-tenant isolation, GPU health monitoring, and a built-in web dashboard.

Built by Tristen Markham as part of the [Sentari OS](https://github.com/TristenMarkham) platform.

**Live dashboard:** [https://app.stratagate.dev/ui](https://app.stratagate.dev/ui)

---

## What is Strata?

Strata sits between your AI application and your model backend. It handles:

- **OpenAI-compatible API** — `/v1/chat/completions` so any tool that uses OpenAI can point at Strata
- **Backend agnostic** — supports Ollama, llama.cpp, vLLM, and OpenAI via config
- **JWT Authentication** — every request is verified
- **Tenant Isolation** — requests are scoped per tenant
- **Request Queuing** — prevents GPU overload
- **Rate Limiting** — 15 requests per 5 minutes per user
- **Streaming** — token-by-token responses via SSE
- **Model Registry** — register and manage multiple models
- **Model Pulling** — `strata pull llama3` with progress bar and quantization support
- **Request Logging** — full audit trail of every inference
- **Configurable System Prompt** — platform-level identity via `strata.config.json`
- **Web UI** — dashboard at `/ui` showing models, queue, logs, GPU health
- **GPU Health** — auto-detects local and remote GPUs via SSH, zero footprint
- **Webhook Notifications** — alerts on rate limit hits and model errors
- **Docker support** — `docker compose up -d`
- **CLI** — manage Strata from the command line

---

## Requirements

- Ubuntu 22.04+ or macOS
- Node.js 20+
- NVIDIA GPU (optional — CPU inference supported)
- Ollama, llama.cpp, vLLM, or OpenAI as the model backend

---

## Installation

```bash
git clone https://github.com/TristenMarkham/Strata.git
cd Strata
sudo bash install.sh
```

The installer will:
- Detect your OS (Linux or macOS)
- Install Node.js if needed
- Ask for your backend URL, model, and system prompt
- Auto-detect GPUs (local and remote)
- Generate a JWT secret
- Set up a systemd service (Linux) or LaunchAgent (macOS)
- Optionally install Cloudflare Tunnel for public HTTPS access

---

## Configuration

Edit `strata.config.json`:

```json
{
  "port": 11435,
  "backend": "ollama",
  "backendUrl": "http://localhost:11434",
  "defaultModel": "llama3",
  "systemPrompt": "You are an AI assistant running on the Strata platform.",
  "webhookUrl": null,
  "gpuSsh": []
}
```

**Backend options:** `ollama` | `llama.cpp` | `vllm` | `openai`

**GPU monitoring** — Strata auto-detects GPUs on the local machine and backend host. For additional GPU machines:

```json
"gpuSsh": [
  { "host": "10.0.0.238", "user": "ubuntu" },
  { "host": "10.0.0.239", "user": "ubuntu" }
]
```

No agent needed on GPU machines — Strata SSHes in and runs `nvidia-smi` directly.

---

## OpenAI-Compatible API

Point any OpenAI client at Strata:

```python
import openai
client = openai.OpenAI(
    base_url="http://localhost:11435/v1",
    api_key="your-jwt-token"
)
response = client.chat.completions.create(
    model="llama3",
    messages=[{"role": "user", "content": "Hello"}]
)
```

| Tool | Setting | Value |
|---|---|---|
| Open WebUI | API Base URL | `http://YOUR_IP:11435/v1` |
| Continue.dev | `apiBase` | `http://YOUR_IP:11435/v1` |
| Cursor | OpenAI Base URL | `http://YOUR_IP:11435/v1` |
| LiteLLM | `api_base` | `http://YOUR_IP:11435/v1` |

---

## CLI

```bash
strata status              # Server status + GPU health
strata list                # List registered models
strata pull llama3         # Pull a model via Ollama
strata pull llama3:q4_0    # Pull with quantization
strata register <name>     # Register a model
strata logs [n]            # Show last n request logs
strata tail                # Tail server log live
strata config              # Show current config
strata version             # Show version
strata help                # Show help
```

---

## Web UI

Access the dashboard at:
- **Local:** `http://localhost:11435/ui`
- **Network:** `http://YOUR_IP:11435/ui`
- **Public:** `https://app.stratagate.dev/ui`

The dashboard shows:
- Gateway status, backend, auth
- Request stats (total, success rate, avg response time)
- GPU health (temp, VRAM, utilization, power draw)
- Request logs with API type and timing
- Webhook alerts

---

## Docker

```bash
# Build and run
docker compose up -d

# One liner (coming soon)
docker run -d -p 11435:11435 --env-file .env tristenmarkham/strata
```

---

## Architecture

```
Your App → Strata (port 11435) → Ollama / llama.cpp / vLLM / OpenAI → GPU
```

Strata is designed to eventually run llama.cpp directly, removing the dependency on Ollama entirely. Switch backends by changing one line in `strata.config.json`.

---

## Roadmap

- [x] OpenAI-compatible API
- [x] Backend agnostic (Ollama, llama.cpp, vLLM, OpenAI)
- [x] Model pulling with quantization
- [x] Configurable system prompt
- [x] Web UI dashboard
- [x] GPU health monitoring
- [x] Docker support
- [x] Mac + Linux installer with Cloudflare Tunnel
- [ ] llama.cpp direct integration (remove Ollama dependency)
- [ ] Multi-GPU load balancing
- [ ] Chairman integration for multi-tenant deployment
- [ ] Training pipeline integration
- [ ] Windows installer

---

## Part of Sentari OS

Strata is the model runtime layer of the Sentari OS platform — an enterprise AI operating system for businesses.

---

## License

Proprietary — © 2026 Tristen Markham. All rights reserved.
