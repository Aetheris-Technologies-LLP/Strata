#!/bin/bash
set -e

STRATA_VERSION="0.1.0"
STRATA_PORT=11435
INSTALL_DIR="/opt/strata"
LOG_DIR="/var/log/strata"
SERVICE_USER="strata"

echo ""
echo "🌊 Strata v${STRATA_VERSION} Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Check root ────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root: sudo bash install.sh"
  exit 1
fi

# ── Check OS ──────────────────────────────────────
if [ ! -f /etc/os-release ]; then
  echo "❌ Unsupported OS"
  exit 1
fi
source /etc/os-release
echo "✅ OS: $PRETTY_NAME"

# ── Check Node.js ─────────────────────────────────
if ! command -v node &> /dev/null; then
  echo "📦 Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
NODE_VERSION=$(node --version)
echo "✅ Node.js: $NODE_VERSION"

# ── Check GPU ─────────────────────────────────────
if command -v nvidia-smi &> /dev/null; then
  GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  echo "✅ GPU: $GPU"
else
  echo "⚠️  No NVIDIA GPU detected — CPU inference only"
fi

# ── Check Git ─────────────────────────────────────
if ! command -v git &> /dev/null; then
  echo "📦 Installing git..."
  apt-get install -y git
fi
echo "✅ Git: $(git --version)"

# ── Create service user ───────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
  useradd --system --no-create-home --shell /bin/false $SERVICE_USER
  echo "✅ Created service user: $SERVICE_USER"
fi

# ── Create directories ────────────────────────────
mkdir -p $INSTALL_DIR $LOG_DIR
chown $SERVICE_USER:$SERVICE_USER $LOG_DIR
echo "✅ Directories: $INSTALL_DIR, $LOG_DIR"

# ── Clone or update Strata ────────────────────────
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "📦 Updating Strata..."
  cd $INSTALL_DIR && git pull origin main
else
  echo "📦 Installing Strata..."
  git clone https://github.com/TristenMarkham/Strata.git $INSTALL_DIR
fi
cd $INSTALL_DIR
npm install --production
echo "✅ Strata installed"

# ── Generate JWT secret ───────────────────────────
JWT_SECRET=$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'))")

# ── Create .env ───────────────────────────────────
if [ ! -f "$INSTALL_DIR/.env" ]; then
  cat > $INSTALL_DIR/.env << ENVEOF
STRATA_PORT=${STRATA_PORT}
OLLAMA_URL=http://localhost:11434
JWT_ACCESS_SECRET=${JWT_SECRET}
STRATA_LOG=${LOG_DIR}/requests.log
ENVEOF
  echo "✅ Created .env with generated JWT secret"
else
  echo "⚠️  .env already exists — skipping (edit manually if needed)"
fi

# ── Create systemd service ────────────────────────
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
echo "✅ Systemd service installed and started"

# ── Install CLI ───────────────────────────────────
chmod +x $INSTALL_DIR/cli.js
ln -sf $INSTALL_DIR/cli.js /usr/local/bin/strata
echo "✅ CLI installed: strata"

# ── Wait for startup ──────────────────────────────
echo ""
echo "⏳ Waiting for Strata to start..."
sleep 3

# ── Verify ────────────────────────────────────────
if curl -s http://localhost:${STRATA_PORT}/health | grep -q "online"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🌊 Strata v${STRATA_VERSION} installed successfully!"
  echo ""
  echo "   Port:    ${STRATA_PORT}"
  echo "   Config:  ${INSTALL_DIR}/.env"
  echo "   Logs:    ${LOG_DIR}/strata.log"
  echo ""
  echo "   Run: strata status"
  echo "   Run: strata list"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
else
  echo "❌ Strata failed to start. Check logs: tail -f ${LOG_DIR}/strata.log"
  exit 1
fi
