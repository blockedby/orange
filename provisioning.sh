#!/bin/bash
# Armbian: выполняется один раз после первого входа (root).
# Ставит Python (pip/venv), Node.js, Go и опционально тулзы для Pico.
set -e

ARCH=$(uname -m)
echo "[provisioning] arch=$ARCH"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl wget gnupg

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

# --- Опционально: Pico (picotool и зависимости для Pico SDK) ---
# Раскомментируй, если нужен тулчейн под Raspberry Pi Pico.
# echo "[provisioning] Installing Pico toolchain deps..."
# apt-get install -y cmake gcc-arm-none-eabi libnewlib-arm-none-eabi

echo "[provisioning] Done."
