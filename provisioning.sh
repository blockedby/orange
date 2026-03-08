#!/bin/bash
# Armbian: выполняется один раз после первого входа (root).
# Ставит Python (pip/venv), Node.js, Go и опционально тулзы для Pico.
set -e

ARCH=$(uname -m)
echo "[provisioning] arch=$ARCH"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl wget gnupg git net-tools make
apt-get upgrade -y

# --- Swap 1 GB (файл в образе, подхватится при загрузке по fstab) ---
echo "[provisioning] Creating 1 GB swap file..."
SWAPFILE=/swapfile
SWAP_MB=1024
touch "$SWAPFILE"
chmod 600 "$SWAPFILE"
dd if=/dev/zero of="$SWAPFILE" bs=1M count=$SWAP_MB status=none
mkswap "$SWAPFILE"
echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
swapon "$SWAPFILE" 2>/dev/null || true

# --- Python ---
echo "[provisioning] Installing Python (pip, venv)..."
apt-get install -y python3 python3-pip python3-venv
python3 --version

# --- Node.js ---
echo "[provisioning] Installing Node.js..."
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "x86_64" ]; then
  # NodeSource для arm64 / x86_64
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  NODE_MAJOR=20
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y nodejs
else
  # 32-bit (Orange Pi One и т.п.) — бинарник с nodejs.org
  NODE_VER=20.18.0
  NODE_ARCH=linux-armv7l
  wget -q "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-${NODE_ARCH}.tar.xz" -O /tmp/node.tar.xz
  tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
  rm -f /tmp/node.tar.xz
fi
node --version
npm --version

# --- Go ---
echo "[provisioning] Installing Go..."
case "$ARCH" in
  aarch64) GO_ARCH=linux-arm64 ;;
  armv7l|armhf) GO_ARCH=linux-armv6l ;;
  x86_64) GO_ARCH=linux-amd64 ;;
  *) GO_ARCH=linux-arm64 ;; # fallback
esac
GO_VER=1.23.2
wget -q "https://go.dev/dl/go${GO_VER}.${GO_ARCH}.tar.gz" -O /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm -f /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
export PATH=$PATH:/usr/local/go/bin
go version

# --- Rust (rustup + cargo), системно в /opt ---
echo "[provisioning] Installing Rust (rustup, cargo)..."
apt-get install -y build-essential
export RUSTUP_HOME=/opt/rustup
export CARGO_HOME=/opt/cargo
curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable
echo 'export PATH=$PATH:/opt/cargo/bin' > /etc/profile.d/rust.sh
export PATH=$PATH:/opt/cargo/bin
rustc --version
cargo --version

# --- ZeroClaw (zeroclaw-labs/zeroclaw) — AI assistant runtime ---
echo "[provisioning] Installing ZeroClaw..."
case "$ARCH" in
  aarch64) ZEROCLAW_ARCH=aarch64-unknown-linux-gnu ;;
  armv7l|armhf) ZEROCLAW_ARCH=armv7-unknown-linux-gnueabihf ;;
  x86_64) ZEROCLAW_ARCH=x86_64-unknown-linux-gnu ;;
  *) echo "[provisioning] ZeroClaw: no prebuilt for $ARCH, skip." ; ZEROCLAW_ARCH= ;;
esac
if [ -n "$ZEROCLAW_ARCH" ]; then
  ZEROCLAW_URL="https://github.com/zeroclaw-labs/zeroclaw/releases/latest/download/zeroclaw-${ZEROCLAW_ARCH}.tar.gz"
  wget -q "$ZEROCLAW_URL" -O /tmp/zeroclaw.tar.gz
  tar -xzf /tmp/zeroclaw.tar.gz -C /tmp
  install -m 0755 /tmp/zeroclaw /usr/local/bin/zeroclaw
  rm -f /tmp/zeroclaw /tmp/zeroclaw.tar.gz
  zeroclaw --version || true
fi

# --- SSH: включаем и при необходимости кладём ключ для root ---
echo "[provisioning] Configuring SSH..."
apt-get install -y openssh-server
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
if [[ -f /root/.ssh_authorized_keys.in ]]; then
  mkdir -p /root/.ssh
  mv /root/.ssh_authorized_keys.in /root/.ssh/authorized_keys
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys
  echo "[provisioning] Root authorized_keys installed (use ssh root@<ip>)"
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null || true
  grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
else
  rm -f /root/.ssh_authorized_keys.in
fi

# --- ZeroClaw: преконфиг с OpenRouter, если при сборке передан API key (файл .openrouter_key.in) ---
if [[ -f /root/.openrouter_key.in ]]; then
  OPENROUTER_API_KEY=$(cat /root/.openrouter_key.in)
  rm -f /root/.openrouter_key.in
  OPENROUTER_MODEL="openrouter/auto"
  [[ -f /root/.openrouter_model.in ]] && OPENROUTER_MODEL=$(cat /root/.openrouter_model.in) && rm -f /root/.openrouter_model.in
  echo "[provisioning] Writing ZeroClaw config with OpenRouter (model: ${OPENROUTER_MODEL})..."
  mkdir -p /root/.zeroclaw
  cat > /root/.zeroclaw/config.toml << EOF
# Pre-configured at image build (OPENROUTER_API_KEY, OPENROUTER_MODEL)
default_provider = "openrouter"
default_model = "${OPENROUTER_MODEL}"
api_key = "${OPENROUTER_API_KEY}"

[memory]
backend = "sqlite"
auto_save = true
embedding_provider = "none"
vector_weight = 0.7
keyword_weight = 0.3

[gateway]
port = 42617
host = "127.0.0.1"
require_pairing = true
allow_public_bind = false
EOF
  chmod 600 /root/.zeroclaw/config.toml
  echo "[provisioning] zeroclaw agent will use OpenRouter out of the box"
fi

# --- Опционально: два варианта тулчейна (включить при сборке: PROVISION_PICO=1 или PROVISION_NANO=1) ---
# Pico: Raspberry Pi Pico (RP2040), ARM Cortex-M0+
# Nano: Arduino Nano и совместимые (AVR 8-bit)
if [[ -f /root/.provision_pico ]]; then
  echo "[provisioning] Installing Pico toolchain (RP2040 / Raspberry Pi Pico)..."
  apt-get install -y cmake gcc-arm-none-eabi libnewlib-arm-none-eabi
  rm -f /root/.provision_pico
fi
if [[ -f /root/.provision_nano ]]; then
  echo "[provisioning] Installing Nano toolchain (AVR / Arduino Nano)..."
  apt-get install -y gcc-avr avrdude
  rm -f /root/.provision_nano
fi

echo "[provisioning] Done."
