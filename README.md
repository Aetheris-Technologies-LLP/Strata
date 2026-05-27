# 🌊 Strata

**Strata** is an enterprise model runtime for AI inference — a drop-in replacement for Ollama built for multi-tenant platforms.

Built by Tristen Markham as part of the [Sentari OS](https://github.com/TristenMarkham) platform.

---

## What is Strata?

Strata sits between your AI application and your model backend. It handles:

- **JWT Authentication** — every request is verified
- **Tenant Isolation** — requests are scoped per tenant
- **Request Queuing** — prevents GPU overload
- **Rate Limiting** — 15 requests per 5 minutes per user
- **Streaming** — token-by-token responses via SSE
- **Model Registry** — register and manage multiple models
- **Request Logging** — full audit trail of every inference
- **Base System Prompt** — platform-level identity injected into every request
- **CLI** — manage Strata from the command line

---

## Requirements

- Ubuntu 22.04+
- Node.js 20+
- NVIDIA GPU (optional — CPU inference supported)
- Ollama or llama.cpp as the model backend

---

## Installation

```bash
git clone https://github.com/TristenMarkham/Strata.git
cd Strata
sudo bash install.sh
```

---

## Configuration

Edit `/opt/strata/.env`:

```env
STRATA_PORT=11435
OLLAMA_URL=http://localhost:11434
JWT_ACCESS_SECRET=your_secret_here
STRATA_LOG=/var/log/strata/requests.log
```

---

## API

### Health check
Public endpoint. Returns server status, queue depth, and registered models.

### Inference
### Streaming inference
### List models
### Register model
---

## CLI

```bash
strata status        # Server status
strata list          # List registered models
strata register      # Register a model
strata logs [n]      # Show last n request logs
strata tail          # Tail server log live
strata version       # Show version
strata help          # Show help
```

---

## Architecture
Strata is designed to eventually run llama.cpp directly, removing the dependency on Ollama entirely.

---

## Roadmap

- [ ] llama.cpp direct integration
- [ ] Model downloading and management
- [ ] Cross-platform installers (Mac, Windows)
- [ ] Web dashboard
- [ ] Chairman integration for multi-tenant deployment
- [ ] Training pipeline integration

---

## Part of Sentari OS

Strata is the model runtime layer of the Sentari OS platform — an enterprise AI operating system for businesses.

---

## License

Proprietary — © 2026 Tristen Markham. All rights reserved.
