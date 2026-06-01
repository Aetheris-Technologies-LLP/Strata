#!/bin/bash
set -e

STRATA_VERSION="0.2.0"
STRATA_PORT=11435
REPO="TristenMarkham/Strata"

echo ""
echo "🌊 Strata v${STRATA_VERSION} Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Detect OS ─────────────────────────────────────────────────────────────────
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
  elif [ -f /etc/os-release ]; then
    source /etc/os-release
    OS="linux"
    DISTRO="$ID"
    echo "✅ OS: $PRETTY_NAME"
  else
    echo "❌ Unsupported OS"
    exit 1
  fi
}

detect_os

# ── macOS path ────────────────────────────────────────────────────────────────
if [ "$OS" = "macos" ]; then
  INSTALL_DIR="$HOME/.strata"
  LOG_DIR="$HOME/.strata/logs"
  SERVICE_USER="$USER"

  echo "✅ OS: macOS"

  # Check Homebrew
  if ! command -v brew &> /dev/null; then
    echo "📦 Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  # Node.js
  if ! command -v node &> /dev/null; then
    echo "📦 Installing Node.js..."
    brew install node
  fi
  echo "✅ Node.js: $(node --version)"

  # Git
  if ! command -v git &> /dev/null; then
    brew install git
  fi

  # Create dirs
  mkdir -p "$INSTALL_DIR" "$LOG_DIR"

  # Clone or update
  if [ -d "$INSTALL_DIR/.git" ]; then
    echo "📦 Updating Strata..."
    cd "$INSTALL_DIR" && git pull
  else
    echo "📦 Cloning Strata..."
    git clone "https://github.com/$REPO.git" "$INSTALL_DIR" 2>/dev/null || {
      echo "⚠️  Could not clone (private repo). Copy files manually to $INSTALL_DIR"
    }
  fi

  cd "$INSTALL_DIR"

  # Install dependencies
  echo "📦 Installing dependencies..."
  npm install --omit=dev --silent

  # Generate JWT secret
  JWT_SECRET=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")

  # Write config
  if [ ! -f "$INSTALL_DIR/strata.config.json" ]; then
    cat > "$INSTALL_DIR/strata.config.json" << CFGEOF
{
  "port": ${STRATA_PORT},
  "backend": "ollama",
  "backendUrl": "http://localhost:11434",
  "defaultModel": "mixtral",
  "systemPrompt": "You are a helpful AI assistant.",
  "logFile": "${LOG_DIR}/requests.log"
}
CFGEOF
    echo "✅ Created strata.config.json"
  fi

  if [ ! -f "$INSTALL_DIR/.env" ]; then
    cat > "$INSTALL_DIR/.env" << ENVEOF
STRATA_PORT=${STRATA_PORT}
OLLAMA_URL=http://localhost:11434
JWT_ACCESS_SECRET=${JWT_SECRET}
STRATA_LOG=${LOG_DIR}/requests.log
ENVEOF
    echo "✅ Created .env"
  fi

  # CLI symlink
  chmod +x "$INSTALL_DIR/cli.js"
  sudo ln -sf "$INSTALL_DIR/cli.js" /usr/local/bin/strata
  echo "✅ CLI installed: strata"

  # LaunchAgent (macOS service)
  PLIST="$HOME/Library/LaunchAgents/com.strata.plist"
  cat > "$PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.strata</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/node</string>
    <string>${INSTALL_DIR}/server.js</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${INSTALL_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/strata.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/strata.log</string>
</dict>
</plist>
PLISTEOF

  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "✅ LaunchAgent installed (starts on login)"

  # ── Optional: Cloudflare Tunnel ─────────────────────────────────────────────
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -p "🌐 Install Cloudflare Tunnel for public HTTPS access? (recommended) [y/N]: " CF_ANSWER
  CF_URL=""
  if [[ "$CF_ANSWER" =~ ^[Yy]$ ]]; then
    echo "📦 Installing cloudflared..."
    brew install cloudflared 2>/dev/null || {
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz | tar xz
      sudo mv cloudflared /usr/local/bin/
    }
    # Run as background LaunchAgent
    TUNNEL_PLIST="$HOME/Library/LaunchAgents/com.strata.tunnel.plist"
    cat > "$TUNNEL_PLIST" << TEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.strata.tunnel</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/cloudflared</string>
    <string>tunnel</string>
    <string>--url</string>
    <string>http://localhost:${STRATA_PORT}</string>
    <string>--no-autoupdate</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/tunnel.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/tunnel.log</string>
</dict>
</plist>
TEOF
    launchctl load "$TUNNEL_PLIST"
    echo "✅ Cloudflare Tunnel installed"
    sleep 3
    TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' ${LOG_DIR}/tunnel.log 2>/dev/null | tail -1)
    if [ -n "$TUNNEL_URL" ]; then
      echo "   ✅ Public URL: ${TUNNEL_URL}/ui"
      CF_URL="${TUNNEL_URL}"
    else
      echo "   ⏳ Tunnel starting — check: tail -f ${LOG_DIR}/tunnel.log"
      CF_URL="(check tunnel.log for URL)"
    fi
  fi

  sleep 2
  if curl -s http://localhost:${STRATA_PORT}/health | grep -q "online"; then
    LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "YOUR_IP")
    PUBLIC_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "YOUR_PUBLIC_IP")
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🌊 Strata v${STRATA_VERSION} installed!"
    echo ""
    echo "   Config: ${INSTALL_DIR}/strata.config.json"
    echo "   Logs:   ${LOG_DIR}/strata.log"
    echo ""
    echo "   ── Access your Strata dashboard ──"
    echo ""
    echo "   Local network:"
    echo "   http://${LOCAL_IP}:${STRATA_PORT}/ui"
    echo ""
    echo "   To access from anywhere (pick one):"
    echo "   • Port forward ${STRATA_PORT} on your router:"
    echo "     http://${PUBLIC_IP}:${STRATA_PORT}/ui"
    if [ -n "$CF_URL" ]; then
    echo "   • Cloudflare Tunnel (active):"
    echo "     ${CF_URL}/ui"
    else
    echo "   • Cloudflare Tunnel (free, recommended):"
    echo "     cloudflared tunnel --url http://localhost:${STRATA_PORT}"
    fi
    echo "   • Quick test with ngrok:"
    echo "     npx ngrok http ${STRATA_PORT}"
    if [ -n "$TAILSCALE_IP" ]; then
    echo "   • Tailscale:"
    echo "     http://${TAILSCALE_IP}:${STRATA_PORT}/ui"
    fi
    echo ""
    echo "   ── OpenAI-compatible API ──"
    echo "   http://${LOCAL_IP}:${STRATA_PORT}/v1"
    echo ""
    echo "   Run: strata status"
    echo "   Run: strata pull llama3"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  else
    echo "❌ Strata failed to start. Check: tail -f ${LOG_DIR}/strata.log"
    exit 1
  fi
  exit 0
fi

# ── Linux path ────────────────────────────────────────────────────────────────
# Must be root on Linux
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root on Linux: sudo bash install.sh"
  exit 1
fi

INSTALL_DIR="/opt/strata"
LOG_DIR="/var/log/strata"
SERVICE_USER="strata"

# Node.js
if ! command -v node &> /dev/null; then
  echo "📦 Installing Node.js 20..."
  if command -v apt-get &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  elif command -v yum &> /dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    yum install -y nodejs
  elif command -v pacman &> /dev/null; then
    pacman -Sy --noconfirm nodejs npm
  else
    echo "❌ Could not install Node.js. Install manually and re-run."
    exit 1
  fi
fi
echo "✅ Node.js: $(node --version)"

# Git
if ! command -v git &> /dev/null; then
  apt-get install -y git 2>/dev/null || yum install -y git 2>/dev/null || true
fi

# Create service user
if ! id "$SERVICE_USER" &>/dev/null; then
  useradd -r -s /bin/false "$SERVICE_USER"
  echo "✅ Created system user: $SERVICE_USER"
fi

# Create dirs
mkdir -p "$INSTALL_DIR" "$LOG_DIR"
chown "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"

# Clone or update
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "📦 Updating Strata..."
  cd "$INSTALL_DIR" && git pull
else
  echo "📦 Cloning Strata..."
  git clone "https://github.com/$REPO.git" "$INSTALL_DIR" 2>/dev/null || {
    echo "⚠️  Could not clone (private repo). Copy files manually to $INSTALL_DIR"
  }
fi

cd "$INSTALL_DIR"
npm install --omit=dev --silent
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
echo "✅ Dependencies installed"

# Generate JWT secret
JWT_SECRET=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")

# ── Smart setup — ask questions, auto-detect ──────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚙️  Strata Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Backend
read -p "Backend type (ollama/llama.cpp/vllm/openai) [ollama]: " BACKEND_TYPE
BACKEND_TYPE=${BACKEND_TYPE:-ollama}

read -p "Backend URL [http://localhost:11434]: " BACKEND_URL
BACKEND_URL=${BACKEND_URL:-http://localhost:11434}

read -p "Default model [llama3]: " DEFAULT_MODEL
DEFAULT_MODEL=${DEFAULT_MODEL:-llama3}

read -p "System prompt [You are an AI assistant running on the Strata platform.]: " SYSTEM_PROMPT
SYSTEM_PROMPT=${SYSTEM_PROMPT:-You are an AI assistant running on the Strata platform.}

# GPU auto-detect
echo ""
echo "🔍 Detecting GPUs..."
GPU_SSH_JSON="[]"

# Check local GPU
if command -v nvidia-smi &> /dev/null; then
  LOCAL_GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  if [ -n "$LOCAL_GPU" ]; then
    echo "✅ Local GPU found: $LOCAL_GPU"
    GPU_SSH_JSON="[]"  # local is auto-detected, no SSH needed
  fi
else
  echo "   No local GPU detected"
fi

# Check backend host for GPU
BACKEND_HOST=$(echo "$BACKEND_URL" | sed 's|http://||' | sed 's|https://||' | cut -d: -f1)
if [ "$BACKEND_HOST" != "localhost" ] && [ "$BACKEND_HOST" != "127.0.0.1" ]; then
  SSH_USER=$(whoami)
  REMOTE_GPU=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
    "$SSH_USER@$BACKEND_HOST" \
    "nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1" 2>/dev/null)
  if [ -n "$REMOTE_GPU" ]; then
    echo "✅ Remote GPU found on $BACKEND_HOST: $REMOTE_GPU"
    GPU_SSH_JSON="[]"  # auto-detected via backend host, no extra config needed
  fi
fi

# Ask about additional GPU machines
read -p "Do you have GPUs on additional machines? [y/N]: " EXTRA_GPU
GPU_EXTRA_JSON=""
if [[ "$EXTRA_GPU" =~ ^[Yy]$ ]]; then
  GPU_ENTRIES="["
  FIRST=true
  while true; do
    read -p "   GPU machine IP: " GPU_HOST
    read -p "   SSH username [$SSH_USER]: " GPU_USER
    GPU_USER=${GPU_USER:-$SSH_USER}
    if [ "$FIRST" = true ]; then
      GPU_ENTRIES="${GPU_ENTRIES}{\"host\":\"${GPU_HOST}\",\"user\":\"${GPU_USER}\"}"
      FIRST=false
    else
      GPU_ENTRIES="${GPU_ENTRIES},{\"host\":\"${GPU_HOST}\",\"user\":\"${GPU_USER}\"}"
    fi
    read -p "   Add another? [y/N]: " MORE_GPU
    [[ "$MORE_GPU" =~ ^[Yy]$ ]] || break
  done
  GPU_SSH_JSON="${GPU_ENTRIES}]"
fi

# Write config
if [ ! -f "$INSTALL_DIR/strata.config.json" ]; then
  cat > "$INSTALL_DIR/strata.config.json" << CFGEOF
{
  "port": ${STRATA_PORT},
  "backend": "${BACKEND_TYPE}",
  "backendUrl": "${BACKEND_URL}",
  "defaultModel": "${DEFAULT_MODEL}",
  "systemPrompt": "${SYSTEM_PROMPT}",
  "logFile": "${LOG_DIR}/requests.log",
  "webhookUrl": null,
  "gpuSsh": ${GPU_SSH_JSON}
}
CFGEOF
  echo "✅ Created strata.config.json"
fi

if [ ! -f "$INSTALL_DIR/.env" ]; then
  cat > "$INSTALL_DIR/.env" << ENVEOF
STRATA_PORT=${STRATA_PORT}
JWT_ACCESS_SECRET=${JWT_SECRET}
STRATA_LOG=${LOG_DIR}/requests.log
ENVEOF
  echo "✅ Created .env with generated JWT secret"
fi

# systemd service
cat > /etc/systemd/system/strata.service << SVCEOF
[Unit]
Description=Strata Model Runtime
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=10
Environment="NODE_ENV=production"
StandardOutput=append:${LOG_DIR}/strata.log
StandardError=append:${LOG_DIR}/strata.log

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable strata
systemctl restart strata
echo "✅ systemd service installed and started"

# CLI
chmod +x "$INSTALL_DIR/cli.js"
ln -sf "$INSTALL_DIR/cli.js" /usr/local/bin/strata
echo "✅ CLI installed: strata"

# ── Optional: Cloudflare Tunnel ───────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -p "🌐 Install Cloudflare Tunnel for public HTTPS access? (recommended) [y/N]: " CF_ANSWER
if [[ "$CF_ANSWER" =~ ^[Yy]$ ]]; then
  echo "📦 Installing cloudflared..."
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared

  # Create systemd service for cloudflared
  cat > /etc/systemd/system/strata-tunnel.service << CFEOF
[Unit]
Description=Strata Cloudflare Tunnel
After=network.target strata.service
Requires=strata.service

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:${STRATA_PORT} --no-autoupdate
Restart=always
RestartSec=10
StandardOutput=append:${LOG_DIR}/tunnel.log
StandardError=append:${LOG_DIR}/tunnel.log

[Install]
WantedBy=multi-user.target
CFEOF

  systemctl daemon-reload
  systemctl enable strata-tunnel
  systemctl start strata-tunnel
  echo "✅ Cloudflare Tunnel installed and started"
  echo "   Your public URL will appear in: tail -f ${LOG_DIR}/tunnel.log"
  sleep 3
  TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' ${LOG_DIR}/tunnel.log 2>/dev/null | tail -1)
  if [ -n "$TUNNEL_URL" ]; then
    echo "   ✅ Public URL: ${TUNNEL_URL}/ui"
    CF_URL="${TUNNEL_URL}"
  else
    echo "   ⏳ Tunnel starting — check URL with: tail -f ${LOG_DIR}/tunnel.log"
    CF_URL="(check tunnel.log for URL)"
  fi
else
  echo "   Skipping Cloudflare Tunnel."
  CF_URL=""
fi

sleep 3

if curl -s http://localhost:${STRATA_PORT}/health | grep -q "online"; then
  LOCAL_IP=$(hostname -I | awk '{print $1}')
  PUBLIC_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "YOUR_PUBLIC_IP")
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🌊 Strata v${STRATA_VERSION} installed!"
  echo ""
  echo "   Config: ${INSTALL_DIR}/strata.config.json"
  echo "   Logs:   ${LOG_DIR}/strata.log"
  echo ""
  echo "   ── Access your Strata dashboard ──"
  echo ""
  echo "   Local network:"
  echo "   http://${LOCAL_IP}:${STRATA_PORT}/ui"
  echo ""
  echo "   To access from anywhere (pick one):"
  echo "   • Port forward ${STRATA_PORT} on your router:"
  echo "     http://${PUBLIC_IP}:${STRATA_PORT}/ui"
  if [ -n "$CF_URL" ]; then
  echo "   • Cloudflare Tunnel (active):"
  echo "     ${CF_URL}/ui"
  else
  echo "   • Cloudflare Tunnel (free, recommended):"
  echo "     cloudflared tunnel --url http://localhost:${STRATA_PORT}"
  fi
  echo "   • Quick test with ngrok:"
  echo "     npx ngrok http ${STRATA_PORT}"
  if [ -n "$TAILSCALE_IP" ]; then
  echo "   • Tailscale:"
  echo "     http://${TAILSCALE_IP}:${STRATA_PORT}/ui"
  fi
  echo ""
  echo "   ── OpenAI-compatible API ──"
  echo "   http://${LOCAL_IP}:${STRATA_PORT}/v1"
  echo ""
  echo "   Run: strata status"
  echo "   Run: strata pull llama3"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  echo "❌ Strata failed to start."
  echo "   Check logs: tail -f ${LOG_DIR}/strata.log"
  exit 1
fi
