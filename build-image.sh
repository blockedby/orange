#!/usr/bin/env bash
# Автономная сборка готового образа Armbian для Orange Pi One:
# скачивает образ, монтирует, в chroot ставит Python, Node, Go, ZeroClaw.
# Результат: один .img 24 GB — записал на флешку и загрузился, ничего не доставляешь.
#
# Запуск: на своей Linux-машине с sudo и сетью:
#   Debian/Ubuntu:  sudo apt-get install -y xz-utils curl qemu-user-static
#   Arch / Stramos: sudo pacman -S --noconfirm xz curl qemu-user-static
#   ./build-image.sh
#
# Опционально (ключи попадут в образ, в лог не пишутся):
#   ROOT_SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
#   OPENROUTER_API_KEY="sk-or-v1-..." \
#   OPENROUTER_MODEL="anthropic/claude-sonnet-4" \
#   ./build-image.sh
# Опционально тулчейн (один или оба): Pico (RP2040) или Nano (AVR/Arduino Nano)
#   PROVISION_PICO=1 ./build-image.sh
#   PROVISION_NANO=1 ./build-image.sh
# По умолчанию: компактный профиль (8 GB, кэш apt 2 GB).
# Переопределение: IMAGE_SIZE_GB=12 APT_CACHE_GB=3 BUILD_PROFILE=full RUN_APT_UPGRADE=1 ./build-image.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
ROOTFS="${BUILD_DIR}/rootfs"
OUTPUT_IMG="${SCRIPT_DIR}/orange-pi-one-ready.img"

BUILD_PROFILE="${BUILD_PROFILE:-minimal}"

if [[ "${BUILD_PROFILE}" == "minimal" ]]; then
  IMAGE_SIZE_GB="${IMAGE_SIZE_GB:-8}"
  APT_CACHE_GB="${APT_CACHE_GB:-2}"
  RUN_APT_UPGRADE="${RUN_APT_UPGRADE:-0}"
else
  IMAGE_SIZE_GB="${IMAGE_SIZE_GB:-24}"
  APT_CACHE_GB="${APT_CACHE_GB:-4}"
  RUN_APT_UPGRADE="${RUN_APT_UPGRADE:-1}"
fi

# Подхватить переменные из .env (если есть)
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  source "${SCRIPT_DIR}/.env"
  set +a
  echo "[build] Loaded .env"
fi

# Рабочая ссылка на образ (можно/нужно переопределять через .env при истечении токена)
ARMBIAN_IMAGE_URL="${ARMBIAN_IMAGE_URL:-https://drive.usercontent.google.com/download?id=1qh6CHMCaPRnc4t62QG-ndzBoQxDE3vos&export=download&authuser=0&confirm=t&uuid=239b4b1d-0bb0-4b21-b7e1-ef8916e8322c&at=AGN2oQ1HI4SMGZ_6_tponiE8EvmG:1774362128800}"
ARMBIAN_IMAGE_ARCHIVE="${BUILD_DIR}/armbian.source"
ARMBIAN_IMAGE_RAW="${BUILD_DIR}/armbian.img"

echo "[build] Output image: ${OUTPUT_IMG}"
echo "[build] Armbian source: ${ARMBIAN_IMAGE_URL}"
echo "[build] Profile: ${BUILD_PROFILE} (IMAGE_SIZE_GB=${IMAGE_SIZE_GB}, APT_CACHE_GB=${APT_CACHE_GB}, RUN_APT_UPGRADE=${RUN_APT_UPGRADE})"
HOST_ARCH=$(uname -m)
echo "[build] Host: ${HOST_ARCH} → target: ARM (Orange Pi One); will use qemu-arm-static in chroot"

require_cmd() {
  for c in "$@"; do
    command -v "$c" &>/dev/null || { echo "Need: $c"; exit 1; }
  done
}
require_cmd curl xz gzip tar mount umount losetup truncate resize2fs
# growpart (cloud-guest-utils) или parted для расширения раздела
command -v growpart &>/dev/null || command -v parted &>/dev/null || { echo "Need: growpart or parted"; exit 1; }
if ! sudo -n true 2>/dev/null; then
  echo "Need sudo (mount/losetup/chroot). Run: sudo ./build-image.sh"
  exit 1
fi

# --- 1. Скачать образ ---
mkdir -p "${BUILD_DIR}"
if [[ ! -f "${ARMBIAN_IMAGE_ARCHIVE}" ]]; then
  echo "[build] Downloading Armbian image..."
  curl -fSL -o "${ARMBIAN_IMAGE_ARCHIVE}" "${ARMBIAN_IMAGE_URL}"
else
  echo "[build] Using cached ${ARMBIAN_IMAGE_ARCHIVE}"
fi
echo "[build] Source archive saved as: ${ARMBIAN_IMAGE_ARCHIVE}"

# --- 2. Распаковать ---
if [[ ! -f "${ARMBIAN_IMAGE_RAW}" ]]; then
  echo "[build] Preparing raw image from downloaded source..."
  if xz -t "${ARMBIAN_IMAGE_ARCHIVE}" >/dev/null 2>&1; then
    echo "[build] Detected format: xz-compressed image"
    cp -f "${ARMBIAN_IMAGE_ARCHIVE}" "${BUILD_DIR}/armbian.img.xz"
    (cd "${BUILD_DIR}" && xz -dk -f armbian.img.xz 2>/dev/null || xz -d -k -f armbian.img.xz)
  elif gzip -t "${ARMBIAN_IMAGE_ARCHIVE}" >/dev/null 2>&1; then
    if tar -tzf "${ARMBIAN_IMAGE_ARCHIVE}" >/dev/null 2>&1; then
      echo "[build] Detected format: tar.gz archive"
      tar -xzf "${ARMBIAN_IMAGE_ARCHIVE}" -C "${BUILD_DIR}"
      IMG_FROM_TAR="$(ls "${BUILD_DIR}"/*.img 2>/dev/null | head -n 1 || true)"
      if [[ -z "${IMG_FROM_TAR}" ]]; then
        echo "[build] ERROR: tar.gz does not contain .img file"
        exit 1
      fi
      cp -f "${IMG_FROM_TAR}" "${ARMBIAN_IMAGE_RAW}"
    else
      echo "[build] Detected format: gzip-compressed image"
      cp -f "${ARMBIAN_IMAGE_ARCHIVE}" "${BUILD_DIR}/armbian.img.gz"
      gzip -df "${BUILD_DIR}/armbian.img.gz"
    fi
  else
    echo "[build] Detected format: raw image (no compression)"
    cp -f "${ARMBIAN_IMAGE_ARCHIVE}" "${ARMBIAN_IMAGE_RAW}"
  fi
fi
test -f "${ARMBIAN_IMAGE_RAW}"

# --- 2b. Расширить образ до IMAGE_SIZE_GB и корневой раздел (больше места под установку) ---
CURRENT_SIZE=$(stat -c%s "${ARMBIAN_IMAGE_RAW}" 2>/dev/null || stat -f%z "${ARMBIAN_IMAGE_RAW}" 2>/dev/null)
TARGET_SIZE=$((IMAGE_SIZE_GB * 1024 * 1024 * 1024))
if [[ "${CURRENT_SIZE}" -lt "${TARGET_SIZE}" ]]; then
  echo "[build] Expanding image to ${IMAGE_SIZE_GB} GB..."
  truncate -s "${IMAGE_SIZE_GB}G" "${ARMBIAN_IMAGE_RAW}"
fi

# --- 3. Монтировать корневой раздел (второй раздел у Armbian) ---
mkdir -p "${ROOTFS}"
LOOP=""
LOOP_APT=""
cleanup_mount() {
  if [[ -d "${ROOTFS}" ]]; then
    sudo umount "${ROOTFS}/var/cache/apt/archives" 2>/dev/null || true
    for m in dev proc sys run; do
      sudo umount "${ROOTFS}/${m}" 2>/dev/null || true
    done
    sudo umount "${ROOTFS}" 2>/dev/null || true
  fi
  [[ -n "${LOOP_APT}" ]] && sudo losetup -d "${LOOP_APT}" 2>/dev/null || true
  [[ -n "${LOOP}" ]] && sudo losetup -d "${LOOP}" 2>/dev/null || true
}
trap cleanup_mount EXIT

echo "[build] Attaching image (sudo)..."
LOOP=$(sudo losetup -f --show -P "${ARMBIAN_IMAGE_RAW}")
ROOT_PART="${LOOP}p2"
ROOT_PART_NUM=2
if [[ ! -e "${ROOT_PART}" ]]; then
  ROOT_PART="${LOOP}p1"
  ROOT_PART_NUM=1
fi
# Расширить раздел до конца образа и файловую систему
echo "[build] Growing partition ${ROOT_PART_NUM} to fill image..."
sudo growpart "${LOOP}" "${ROOT_PART_NUM}" 2>/dev/null || sudo parted -s "${LOOP}" resizepart "${ROOT_PART_NUM}" 100%
sudo mount "${ROOT_PART}" "${ROOTFS}"
echo "[build] Resizing root filesystem to use new space..."
sudo resize2fs "${ROOT_PART}"

# --- 3b. Кэш apt в chroot (${APT_CACHE_GB} GB) ---
APT_CACHE_IMG="${BUILD_DIR}/apt-cache.img"
if [[ ! -f "${APT_CACHE_IMG}" ]]; then
  echo "[build] Creating ${APT_CACHE_GB} GB volume for apt cache..."
  dd if=/dev/zero of="${APT_CACHE_IMG}" bs=1M count=$((APT_CACHE_GB * 1024)) status=none
fi
LOOP_APT=$(sudo losetup -f --show "${APT_CACHE_IMG}")
sudo mkfs.ext4 -q "${LOOP_APT}"
sudo mkdir -p "${ROOTFS}/var/cache/apt/archives"
sudo mount "${LOOP_APT}" "${ROOTFS}/var/cache/apt/archives"
echo "[build] apt cache mounted: ${APT_CACHE_GB} GB at /var/cache/apt/archives"

# --- 4. QEMU для chroot (хост x86 → гость ARM) ---
if [[ "$HOST_ARCH" = "x86_64" ]] || [[ "$HOST_ARCH" = "aarch64" ]]; then
  QEMU_SRC="/usr/bin/qemu-arm-static"
  if [[ -x "${QEMU_SRC}" ]]; then
    sudo mkdir -p "${ROOTFS}/usr/bin"
    sudo cp -a "${QEMU_SRC}" "${ROOTFS}/usr/bin/"
    echo "[build] QEMU user emulation installed for chroot (ARM on ${HOST_ARCH})"
  else
    echo "[build] WARN: qemu-arm-static not found (needed for ARM chroot on ${HOST_ARCH})"
    if command -v pacman &>/dev/null; then
      echo "  Arch/Stramos: sudo pacman -S --noconfirm qemu-user-static"
    else
      echo "  Debian/Ubuntu: sudo apt-get install -y qemu-user-static"
    fi
    echo "  Trying anyway..."
  fi
fi

# --- 5. Копируем provisioning в образ и подготавливаем chroot ---
sudo cp -a "${SCRIPT_DIR}/provisioning.sh" "${ROOTFS}/root/provisioning.sh"
sudo chmod +x "${ROOTFS}/root/provisioning.sh"
echo "nameserver 8.8.8.8" | sudo tee "${ROOTFS}/etc/resolv.conf" >/dev/null
# firstboot.conf → /root/.not_logged_in_yet (пароль, пользователь, локаль при первом запуске)
if [[ -f "${SCRIPT_DIR}/firstboot.conf" ]]; then
  sudo cp -a "${SCRIPT_DIR}/firstboot.conf" "${ROOTFS}/root/.not_logged_in_yet"
  echo "[build] firstboot.conf → /root/.not_logged_in_yet"
fi
# Ключи передаём через файлы (безопасно для спецсимволов), provisioning прочитает и удалит
if [[ -n "${ROOT_SSH_AUTHORIZED_KEYS:-}" ]]; then
  echo "${ROOT_SSH_AUTHORIZED_KEYS}" | sudo tee "${ROOTFS}/root/.ssh_authorized_keys.in" >/dev/null
  sudo chmod 600 "${ROOTFS}/root/.ssh_authorized_keys.in"
  echo "[build] ROOT_SSH_AUTHORIZED_KEYS → will be installed as /root/.ssh/authorized_keys"
fi
if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  echo "${OPENROUTER_API_KEY}" | sudo tee "${ROOTFS}/root/.openrouter_key.in" >/dev/null
  sudo chmod 600 "${ROOTFS}/root/.openrouter_key.in"
  echo "[build] OPENROUTER_API_KEY → will be written to ZeroClaw config"
fi
if [[ -n "${OPENROUTER_MODEL:-}" ]]; then
  echo "${OPENROUTER_MODEL}" | sudo tee "${ROOTFS}/root/.openrouter_model.in" >/dev/null
  echo "[build] OPENROUTER_MODEL=${OPENROUTER_MODEL} → default_model in ZeroClaw config"
fi
# Опционально: тулчейн Pico (RP2040) или Nano (AVR) — какой лучше подберёшь по ходу
[[ -n "${PROVISION_PICO:-}" ]] && sudo touch "${ROOTFS}/root/.provision_pico" && echo "[build] PROVISION_PICO=1 → will install Pico (RP2040) toolchain"
[[ -n "${PROVISION_NANO:-}" ]] && sudo touch "${ROOTFS}/root/.provision_nano" && echo "[build] PROVISION_NANO=1 → will install Nano (AVR) toolchain"
sudo mount --bind /dev "${ROOTFS}/dev"
sudo mount -t proc none "${ROOTFS}/proc"
sudo mount -t sysfs none "${ROOTFS}/sys"
if [[ -d /run ]]; then
  sudo mount --bind /run "${ROOTFS}/run" 2>/dev/null || true
fi

# --- 6. Запуск установки внутри образа (это займёт время) ---
echo "[build] Running provisioning inside image (Python, Node, Go, ZeroClaw, SSH, ZeroClaw config)..."
sudo chroot "${ROOTFS}" /bin/bash -c "export DEBIAN_FRONTEND=noninteractive RUN_APT_UPGRADE='${RUN_APT_UPGRADE}'; /root/provisioning.sh"

# --- 7. Убираем скрипт, чтобы Armbian не запустил его снова при первом входе ---
sudo rm -f "${ROOTFS}/root/provisioning.sh"

# --- 8. Размонтируем ---
sudo umount "${ROOTFS}/var/cache/apt/archives" 2>/dev/null || true
[[ -n "${LOOP_APT}" ]] && sudo losetup -d "${LOOP_APT}" 2>/dev/null || true
for m in run dev proc sys; do
  sudo umount "${ROOTFS}/${m}" 2>/dev/null || true
done
if ! sudo umount "${ROOTFS}" 2>/dev/null; then
  echo "[build] rootfs busy, trying lazy umount..."
  sudo umount -l "${ROOTFS}"
fi
sudo losetup -d "${LOOP}"
LOOP=""
LOOP_APT=""
trap - EXIT

# --- 9. Копируем готовый образ в корень проекта ---
echo "[build] Copying final image to ${OUTPUT_IMG}..."
cp -a "${ARMBIAN_IMAGE_RAW}" "${OUTPUT_IMG}"
# Чтобы образ и build/ были у того, кто запустил sudo, а не у root
if [[ -n "${SUDO_UID:-}" ]] && [[ -n "${SUDO_GID:-}" ]]; then
  sudo chown -R "${SUDO_UID}:${SUDO_GID}" "${OUTPUT_IMG}" "${BUILD_DIR}"
  echo "[build] chown ${SUDO_USER:-$SUDO_UID}:${SUDO_GID} on output and build/"
fi
echo "[build] Done. Image size: $(du -h "${OUTPUT_IMG}" | cut -f1)"
echo "[build] Flash with: sudo dd if=${OUTPUT_IMG} of=/dev/sdX bs=4M status=progress conv=fsync"
echo "[build] Or use: balena-etcher, Armbian Imager, etc. (image: ${IMAGE_SIZE_GB} GB)"
