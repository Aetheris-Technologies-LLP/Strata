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

  sleep 2
  if curl -s http://localhost:${STRATA_PORT}/health | grep -q "online"; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🌊 Strata v${STRATA_VERSION} installed!"
    echo ""
    echo "   Config: ${INSTALL_DIR}/strata.config.json"
    echo "   Logs:   ${LOG_DIR}/strata.log"
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

sleep 3

if curl -s http://localhost:${STRATA_PORT}/health | grep -q "online"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🌊 Strata v${STRATA_VERSION} installed!"
  echo ""
  echo "   Config: ${INSTALL_DIR}/strata.config.json"
  echo "   Logs:   ${LOG_DIR}/strata.log"
  echo ""
  echo "   Run: strata status"
  echo "   Run: strata pull llama3"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  echo "❌ Strata failed to start."
  echo "   Check logs: tail -f ${LOG_DIR}/strata.log"
  exit 1
fi
