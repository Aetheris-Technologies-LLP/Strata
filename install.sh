#!/bin/bash
set -e

STRATA_VERSION="0.2.0"
STRATA_PORT=11435
REPO="TristenMarkham/Strata"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

echo ""
echo -e "${BLUE}🌊 Strata v${STRATA_VERSION} Installer${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ═══════════════════════════════════════
# DETECT OS
# ═══════════════════════════════════════
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "arm64" ]]; then
      OS_VARIANT="macos_arm"
      ok "OS: macOS Apple Silicon (M-series)"
    else
      OS_VARIANT="macos_intel"
      ok "OS: macOS Intel"
    fi
  elif [ -f /etc/os-release ]; then
    source /etc/os-release
    OS="linux"
    DISTRO="$ID"
    DISTRO_LIKE="${ID_LIKE:-}"
    ok "OS: $PRETTY_NAME"

    # Detect package manager
    if command -v apt-get &>/dev/null; then
      PKG_MGR="apt"
    elif command -v dnf &>/dev/null; then
      PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
      PKG_MGR="yum"
    elif command -v pacman &>/dev/null; then
      PKG_MGR="pacman"
    elif command -v zypper &>/dev/null; then
      PKG_MGR="zypper"
    else
      PKG_MGR="unknown"
      warn "Package manager not recognized — you may need to install dependencies manually"
    fi
  else
    warn "OS not recognized"
    echo ""
    echo "Strata requires Node.js 20+ and optionally a GPU backend."
    echo "Manual setup:"
    echo "  1. Install Node.js 20+"
    echo "  2. cd Strata && npm install"
    echo "  3. Edit strata.config.json"
    echo "  4. node server.js"
    echo ""
    read -p "Continue with manual setup? [y/N]: " MANUAL
    [[ "$MANUAL" =~ ^[Yy]$ ]] || exit 1
    OS="unknown"
  fi
}

detect_os

# ═══════════════════════════════════════
# DETECT GPU
# ═══════════════════════════════════════
detect_gpu() {
  GPU_TYPE="none"
  GPU_NAME=""
  GPU_VRAM=""

  if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -n "$GPU_NAME" ]; then
      GPU_TYPE="nvidia"
      ok "GPU: $GPU_NAME (${GPU_VRAM}MB VRAM)"
    fi
  elif command -v rocm-smi &>/dev/null; then
    GPU_TYPE="amd"
    GPU_NAME=$(rocm-smi --showproductname 2>/dev/null | grep -i "card" | head -1 || echo "AMD GPU")
    ok "GPU: $GPU_NAME (AMD ROCm)"
  elif [[ "$OS_VARIANT" == "macos_arm" ]]; then
    GPU_TYPE="apple"
    GPU_NAME="Apple Silicon (Metal)"
    ok "GPU: $GPU_NAME"
  else
    warn "No supported GPU detected — CPU inference only (slower)"
    GPU_TYPE="cpu"
  fi
}

detect_gpu

# ═══════════════════════════════════════
# CHECK FOR REMOTE GPU
# ═══════════════════════════════════════
GPU_SSH_JSON="[]"
check_remote_gpu() {
  if [ "$GPU_TYPE" = "none" ] || [ "$GPU_TYPE" = "cpu" ]; then
    echo ""
    read -p "Do you have a GPU on a remote machine? [y/N]: " HAS_REMOTE_GPU
    if [[ "$HAS_REMOTE_GPU" =~ ^[Yy]$ ]]; then
      read -p "   GPU machine IP: " GPU_HOST
      read -p "   SSH username [$(whoami)]: " GPU_USER
      GPU_USER=${GPU_USER:-$(whoami)}

      # Test SSH connection
      if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "$GPU_USER@$GPU_HOST" "nvidia-smi --query-gpu=name --format=csv,noheader" &>/dev/null; then
        REMOTE_GPU=$(ssh -o StrictHostKeyChecking=no "$GPU_USER@$GPU_HOST" "nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1")
        ok "Remote GPU found: $REMOTE_GPU on $GPU_HOST"
        GPU_SSH_JSON="[{\"host\":\"$GPU_HOST\",\"user\":\"$GPU_USER\"}]"
      else
        warn "Could not connect to $GPU_HOST via SSH — GPU monitoring disabled"
        warn "Set up SSH key access first: ssh-copy-id $GPU_USER@$GPU_HOST"
      fi
    fi
  fi
}

check_remote_gpu

# ═══════════════════════════════════════
# INSTALL NODE.JS
# ═══════════════════════════════════════
install_node() {
  if command -v node &>/dev/null; then
    NODE_VERSION=$(node --version | sed 's/v//' | cut -d. -f1)
    if [ "$NODE_VERSION" -ge 20 ]; then
      ok "Node.js: $(node --version)"
      return
    else
      warn "Node.js $(node --version) found but v20+ required — upgrading"
    fi
  fi

  info "Installing Node.js 20..."

  case "$PKG_MGR" in
    apt)
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs
      ;;
    dnf|yum)
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
      $PKG_MGR install -y nodejs
      ;;
    pacman)
      pacman -Sy --noconfirm nodejs npm
      ;;
    zypper)
      zypper install -y nodejs20
      ;;
    *)
      if [[ "$OS" == "macos" ]]; then
        if ! command -v brew &>/dev/null; then
          info "Installing Homebrew..."
          /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        brew install node
      else
        err "Cannot install Node.js automatically on this system"
        echo "Please install Node.js 20+ manually: https://nodejs.org"
        exit 1
      fi
      ;;
  esac

  ok "Node.js: $(node --version)"
}

install_node

# ═══════════════════════════════════════
# INSTALL llama.cpp (if local GPU)
# ═══════════════════════════════════════
LLAMA_SERVER_PATH=""
install_llama_cpp() {
  if [ "$GPU_TYPE" = "none" ] || [ "$GPU_TYPE" = "cpu" ]; then
    return
  fi

  echo ""
  info "Checking for llama.cpp..."

  if [ -f "$HOME/llama.cpp/build/bin/llama-server" ]; then
    ok "llama.cpp already installed at ~/llama.cpp"
    LLAMA_SERVER_PATH="$HOME/llama.cpp/build/bin/llama-server"
    return
  fi

  read -p "Install llama.cpp for direct GPU inference? (recommended) [Y/n]: " INSTALL_LLAMA
  INSTALL_LLAMA=${INSTALL_LLAMA:-y}
  [[ "$INSTALL_LLAMA" =~ ^[Nn]$ ]] && return

  info "Installing build dependencies..."
  case "$PKG_MGR" in
    apt)    apt-get install -y build-essential cmake git ;;
    dnf|yum) $PKG_MGR install -y gcc gcc-c++ cmake git ;;
    pacman) pacman -Sy --noconfirm base-devel cmake git ;;
    *)
      if [[ "$OS" == "macos" ]]; then
        brew install cmake git
      fi
      ;;
  esac

  info "Cloning llama.cpp..."
  git clone https://github.com/ggerganov/llama.cpp "$HOME/llama.cpp"
  cd "$HOME/llama.cpp"

  info "Building llama.cpp (this takes 5-10 minutes)..."
  case "$GPU_TYPE" in
    nvidia)
      # Add CUDA to PATH if needed
      export PATH=/usr/local/cuda/bin:$PATH
      cmake -B build -DGGML_CUDA=ON
      ;;
    amd)
      cmake -B build -DGGML_HIPBLAS=ON
      ;;
    apple)
      cmake -B build -DGGML_METAL=ON
      ;;
    *)
      cmake -B build
      ;;
  esac

  cmake --build build --config Release -j $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
  cd - >/dev/null

  LLAMA_SERVER_PATH="$HOME/llama.cpp/build/bin/llama-server"
  ok "llama.cpp built successfully"
}

install_llama_cpp

# ═══════════════════════════════════════
# SETUP QUESTIONS
# ═══════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚙️  Strata Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Backend selection
echo "Select inference backend:"
echo "  1) llama.cpp direct (recommended — local GPU)"
echo "  2) vLLM (high concurrency production)"
echo "  3) OpenAI API (cloud, no GPU needed)"
echo "  4) Custom (any OpenAI-compatible endpoint)"
echo ""
read -p "Choice [1]: " BACKEND_CHOICE
BACKEND_CHOICE=${BACKEND_CHOICE:-1}

case "$BACKEND_CHOICE" in
  1)
    BACKEND="strata.direct"
    if [ -n "$LLAMA_SERVER_PATH" ]; then
      read -p "llama-server port [8080]: " LLAMA_PORT
      LLAMA_PORT=${LLAMA_PORT:-8080}
      BACKEND_URL="http://localhost:$LLAMA_PORT"
    else
      read -p "llama-server URL [http://localhost:8080]: " BACKEND_URL
      BACKEND_URL=${BACKEND_URL:-http://localhost:8080}
    fi
    ;;
  2)
    BACKEND="vllm"
    read -p "vLLM URL [http://localhost:8000]: " BACKEND_URL
    BACKEND_URL=${BACKEND_URL:-http://localhost:8000}
    ;;
  3)
    BACKEND="openai"
    BACKEND_URL="https://api.openai.com"
    read -p "OpenAI API key: " OPENAI_KEY
    ;;
  4)
    BACKEND="openai"
    read -p "Custom endpoint URL: " BACKEND_URL
    read -p "API key (leave blank if none): " CUSTOM_KEY
    ;;
  *)
    BACKEND="strata.direct"
    BACKEND_URL="http://localhost:8080"
    ;;
esac

read -p "Default model name [llama3]: " DEFAULT_MODEL
DEFAULT_MODEL=${DEFAULT_MODEL:-llama3}

read -p "System prompt [You are an AI assistant running on the Strata platform.]: " SYSTEM_PROMPT
SYSTEM_PROMPT=${SYSTEM_PROMPT:-You are an AI assistant running on the Strata platform.}

# ═══════════════════════════════════════
# SECURITY SETUP
# ═══════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔒 Security Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Generate JWT secret
JWT_SECRET=$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'))")
ok "Generated JWT secret"

# SSH key for GPU monitoring
if [ "${GPU_SSH_JSON}" != "[]" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
  info "Generating SSH key for GPU monitoring..."
  ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N ""
  ok "SSH key generated: ~/.ssh/id_rsa.pub"
  echo ""
  warn "Copy this key to your GPU machine:"
  echo "   ssh-copy-id $(echo $GPU_SSH_JSON | grep -o '"user":"[^"]*"' | cut -d'"' -f4)@$(echo $GPU_SSH_JSON | grep -o '"host":"[^"]*"' | cut -d'"' -f4)"
fi

# Firewall
setup_firewall() {
  if [[ "$OS" == "linux" ]]; then
    if command -v ufw &>/dev/null; then
      ufw allow $STRATA_PORT/tcp >/dev/null 2>&1 || true
      ok "Firewall: port $STRATA_PORT opened (ufw)"
    elif command -v firewall-cmd &>/dev/null; then
      firewall-cmd --permanent --add-port=$STRATA_PORT/tcp >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      ok "Firewall: port $STRATA_PORT opened (firewalld)"
    else
      warn "No firewall detected — open port $STRATA_PORT manually if needed"
    fi
  fi
}

setup_firewall

# ═══════════════════════════════════════
# INSTALL STRATA
# ═══════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Installing Strata"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Set install directory based on OS and root status
if [[ "$OS" == "macos" ]]; then
  INSTALL_DIR="$HOME/.strata"
  LOG_DIR="$HOME/.strata/logs"
  SERVICE_USER="$USER"
elif [ "$EUID" -eq 0 ]; then
  INSTALL_DIR="/opt/strata"
  LOG_DIR="/var/log/strata"
  SERVICE_USER="strata"
else
  INSTALL_DIR="$HOME/.strata"
  LOG_DIR="$HOME/.strata/logs"
  SERVICE_USER="$USER"
  warn "Running without root — installing to $INSTALL_DIR (system service unavailable)"
fi

mkdir -p "$INSTALL_DIR" "$LOG_DIR"

# Create service user (Linux root only)
if [[ "$OS" == "linux" ]] && [ "$EUID" -eq 0 ] && ! id "$SERVICE_USER" &>/dev/null; then
  useradd -r -s /bin/false "$SERVICE_USER"
  ok "Created service user: $SERVICE_USER"
fi

# Clone or update
if [ -d "$INSTALL_DIR/.git" ]; then
  info "Updating Strata..."
  cd "$INSTALL_DIR" && git pull origin main
else
  info "Installing Strata..."
  git clone "https://github.com/$REPO.git" "$INSTALL_DIR" 2>/dev/null || {
    warn "Could not clone from GitHub — copying local files"
    cp -r "$(dirname "$0")/." "$INSTALL_DIR/" 2>/dev/null || true
  }
fi

cd "$INSTALL_DIR"
npm install --omit=dev --silent
ok "Dependencies installed"

# Write strata.config.json
cat > "$INSTALL_DIR/strata.config.json" << CFGEOF
{
  "port": ${STRATA_PORT},
  "backend": "${BACKEND}",
  "backendUrl": "${BACKEND_URL}",
  "defaultModel": "${DEFAULT_MODEL}",
  "systemPrompt": "${SYSTEM_PROMPT}",
  "logFile": "${LOG_DIR}/requests.log",
  "webhookUrl": null,
  "gpuSsh": ${GPU_SSH_JSON}
}
CFGEOF
ok "Created strata.config.json"

# Write .env
cat > "$INSTALL_DIR/.env" << ENVEOF
STRATA_PORT=${STRATA_PORT}
JWT_ACCESS_SECRET=${JWT_SECRET}
STRATA_LOG=${LOG_DIR}/requests.log
${OPENAI_KEY:+OPENAI_API_KEY=$OPENAI_KEY}
${CUSTOM_KEY:+OPENAI_API_KEY=$CUSTOM_KEY}
ENVEOF
ok "Created .env with generated JWT secret"

# ═══════════════════════════════════════
# SET UP llama-server SERVICE (if applicable)
# ═══════════════════════════════════════
setup_llama_service() {
  [ -z "$LLAMA_SERVER_PATH" ] && return
  [ "$BACKEND" != "strata.direct" ] && return

  # Find model
  read -p "Path to your .gguf model file: " MODEL_PATH
  if [ ! -f "$MODEL_PATH" ]; then
    warn "Model file not found at $MODEL_PATH — skipping llama-server service"
    warn "Start manually: $LLAMA_SERVER_PATH --model YOUR_MODEL.gguf --port $LLAMA_PORT"
    return
  fi

  # GPU layers
  if [ "$GPU_TYPE" = "nvidia" ] && [ -n "$GPU_VRAM" ]; then
    SUGGESTED_LAYERS=$(( GPU_VRAM / 1000 ))
    read -p "GPU layers to load [${SUGGESTED_LAYERS}]: " GPU_LAYERS
    GPU_LAYERS=${GPU_LAYERS:-$SUGGESTED_LAYERS}
  else
    read -p "GPU layers to load [99 = all]: " GPU_LAYERS
    GPU_LAYERS=${GPU_LAYERS:-99}
  fi

  if [[ "$OS" == "linux" ]] && [ "$EUID" -eq 0 ]; then
    cat > /etc/systemd/system/llama-server.service << SVCEOF
[Unit]
Description=Strata Direct — llama.cpp Server
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=${LLAMA_SERVER_PATH} --model ${MODEL_PATH} --host 0.0.0.0 --port ${LLAMA_PORT:-8080} --n-gpu-layers ${GPU_LAYERS} --ctx-size 32768 --flash-attn
Restart=always
RestartSec=10
Environment="PATH=/usr/local/cuda/bin:/usr/bin:/bin"
Environment="LD_LIBRARY_PATH=/usr/local/cuda/lib64"
StandardOutput=append:${LOG_DIR}/llama-server.log
StandardError=append:${LOG_DIR}/llama-server.log

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable llama-server
    systemctl start llama-server
    ok "llama-server service installed and started"

  elif [[ "$OS" == "macos" ]]; then
    LLAMA_PLIST="$HOME/Library/LaunchAgents/com.strata.llama.plist"
    cat > "$LLAMA_PLIST" << PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.strata.llama</string>
  <key>ProgramArguments</key>
  <array>
    <string>${LLAMA_SERVER_PATH}</string>
    <string>--model</string><string>${MODEL_PATH}</string>
    <string>--host</string><string>0.0.0.0</string>
    <string>--port</string><string>${LLAMA_PORT:-8080}</string>
    <string>--n-gpu-layers</string><string>${GPU_LAYERS}</string>
    <string>--ctx-size</string><string>32768</string>
    <string>--flash-attn</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/llama-server.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/llama-server.log</string>
</dict></plist>
PEOF
    launchctl load "$LLAMA_PLIST"
    ok "llama-server LaunchAgent installed"
  fi
}

setup_llama_service

# ═══════════════════════════════════════
# INSTALL STRATA SERVICE
# ═══════════════════════════════════════
install_strata_service() {
  if [[ "$OS" == "linux" ]] && [ "$EUID" -eq 0 ]; then
    [ "$SERVICE_USER" != "$USER" ] && chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$LOG_DIR"

    cat > /etc/systemd/system/strata.service << SVCEOF
[Unit]
Description=Strata Model Gateway
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
    ok "Strata systemd service installed and started"

  elif [[ "$OS" == "macos" ]]; then
    PLIST="$HOME/Library/LaunchAgents/com.strata.plist"
    cat > "$PLIST" << PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.strata</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/node</string>
    <string>${INSTALL_DIR}/server.js</string>
  </array>
  <key>WorkingDirectory</key><string>${INSTALL_DIR}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/strata.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/strata.log</string>
</dict></plist>
PEOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    ok "Strata LaunchAgent installed"

  else
    warn "No system service installed (requires root on Linux)"
    echo "   Start manually: cd $INSTALL_DIR && node server.js"
  fi
}

install_strata_service

# ═══════════════════════════════════════
# CLI
# ═══════════════════════════════════════
chmod +x "$INSTALL_DIR/cli.js"
if [ -w /usr/local/bin ]; then
  ln -sf "$INSTALL_DIR/cli.js" /usr/local/bin/strata
  ok "CLI installed: strata"
elif [ "$EUID" -eq 0 ]; then
  ln -sf "$INSTALL_DIR/cli.js" /usr/local/bin/strata
  ok "CLI installed: strata"
else
  mkdir -p "$HOME/.local/bin"
  ln -sf "$INSTALL_DIR/cli.js" "$HOME/.local/bin/strata"
  ok "CLI installed: ~/.local/bin/strata"
  warn "Add ~/.local/bin to PATH if not already: export PATH=\$HOME/.local/bin:\$PATH"
fi

# ═══════════════════════════════════════
# OPTIONAL: CLOUDFLARE TUNNEL
# ═══════════════════════════════════════
setup_cloudflare() {
  echo ""
  read -p "🌐 Install Cloudflare Tunnel for public HTTPS access? [y/N]: " CF_ANSWER
  CF_URL=""
  [[ ! "$CF_ANSWER" =~ ^[Yy]$ ]] && return

  info "Installing cloudflared..."
  if [[ "$OS" == "macos" ]]; then
    brew install cloudflared 2>/dev/null || {
      curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-$(uname -m).tgz" | tar xz
      sudo mv cloudflared /usr/local/bin/
    }
  else
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
  fi

  if [[ "$OS" == "linux" ]] && [ "$EUID" -eq 0 ]; then
    cat > /etc/systemd/system/strata-tunnel.service << TEOF
[Unit]
Description=Strata Cloudflare Tunnel
After=network.target strata.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:${STRATA_PORT} --no-autoupdate
Restart=always
RestartSec=10
StandardOutput=append:${LOG_DIR}/tunnel.log
StandardError=append:${LOG_DIR}/tunnel.log

[Install]
WantedBy=multi-user.target
TEOF
    systemctl daemon-reload
    systemctl enable strata-tunnel
    systemctl start strata-tunnel
    sleep 3
    CF_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "${LOG_DIR}/tunnel.log" 2>/dev/null | tail -1)

  elif [[ "$OS" == "macos" ]]; then
    TUNNEL_PLIST="$HOME/Library/LaunchAgents/com.strata.tunnel.plist"
    cat > "$TUNNEL_PLIST" << TEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.strata.tunnel</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/cloudflared</string>
    <string>tunnel</string><string>--url</string>
    <string>http://localhost:${STRATA_PORT}</string>
    <string>--no-autoupdate</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/tunnel.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/tunnel.log</string>
</dict></plist>
TEOF
    launchctl load "$TUNNEL_PLIST"
    sleep 3
    CF_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "${LOG_DIR}/tunnel.log" 2>/dev/null | tail -1)
  fi

  if [ -n "$CF_URL" ]; then
    ok "Cloudflare Tunnel: $CF_URL"
  else
    warn "Tunnel starting — check URL: tail -f ${LOG_DIR}/tunnel.log"
  fi
}

setup_cloudflare

# ═══════════════════════════════════════
# VERIFY & SUCCESS
# ═══════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Waiting for Strata to start..."
sleep 5

if curl -s "http://localhost:${STRATA_PORT}/health" | grep -q "online"; then
  LOCAL_IP=""
  if [[ "$OS" == "macos" ]]; then
    LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "YOUR_IP")
  else
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_IP")
  fi
  PUBLIC_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "YOUR_PUBLIC_IP")
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

  echo ""
  echo -e "${GREEN}🌊 Strata v${STRATA_VERSION} installed successfully!${NC}"
  echo ""
  echo "   Config:  ${INSTALL_DIR}/strata.config.json"
  echo "   Logs:    ${LOG_DIR}/"
  echo ""
  echo "   ── Access your Strata dashboard ──"
  echo ""
  echo "   Local:       http://${LOCAL_IP}:${STRATA_PORT}/ui"
  echo ""
  echo "   From anywhere:"
  echo "   • Port forward ${STRATA_PORT} on your router:"
  echo "     http://${PUBLIC_IP}:${STRATA_PORT}/ui"
  [ -n "$CF_URL" ] && echo "   • Cloudflare:  ${CF_URL}/ui"
  [ -n "$TAILSCALE_IP" ] && echo "   • Tailscale:   http://${TAILSCALE_IP}:${STRATA_PORT}/ui"
  echo "   • ngrok:       npx ngrok http ${STRATA_PORT}"
  echo ""
  echo "   ── OpenAI-compatible API ──"
  echo "   http://${LOCAL_IP}:${STRATA_PORT}/v1"
  echo ""
  echo "   ── CLI ──"
  echo "   strata status"
  echo "   strata pull llama3"
  echo "   strata logs"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  err "Strata failed to start"
  echo "   Check logs: tail -f ${LOG_DIR}/strata.log"
  exit 1
fi
