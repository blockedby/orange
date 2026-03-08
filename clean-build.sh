#!/usr/bin/env bash
# Очистка артефактов сборки (освобождает десятки GB на хосте).
# Размонтирует build/rootfs и loop-устройства, удаляет build/ и готовый образ.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "${SCRIPT_DIR}"
echo "[clean] Unmounting and removing build artifacts..."
sudo umount "${SCRIPT_DIR}/build/rootfs/var/cache/apt/archives" 2>/dev/null || true
sudo umount -l "${SCRIPT_DIR}/build/rootfs" 2>/dev/null || true
sudo losetup -D 2>/dev/null || true
rm -rf "${SCRIPT_DIR}/build"
rm -f "${SCRIPT_DIR}/orange-pi-one-ready.img"
echo "[clean] Done. Freed space from build/ and orange-pi-one-ready.img"
