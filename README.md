# Orange Pi + Armbian: образ «всё сразу»

Два варианта: **готовый образ одной командой** (рекомендуется) или ручная подготовка флешки.

---

## Готовый образ одной командой (без полдня установки)

На **своей Linux-машине** (не в контейнере, с sudo и сетью) один раз установи зависимости и запусти сборку:

**Debian / Ubuntu:**
```bash
cd /path/to/orange
sudo apt-get install -y xz-utils curl qemu-user-static
./build-image.sh
```

**Arch Linux / Stramos (pacman):**
```bash
cd /path/to/orange
sudo pacman -S --noconfirm xz curl qemu-user-static
./build-image.sh
```

Скрипт **сам**:
- скачает образ Armbian Minimal для Orange Pi One (Ubuntu 24.04);
- распакует, смонтирует, в chroot поставит Python, Node, Go, ZeroClaw;
- соберёт один файл **`orange-pi-one-ready.img`** в этой папке.

Дальше:
1. Записать образ на флешку **16 GB**: `sudo dd if=orange-pi-one-ready.img of=/dev/sdX bs=4M status=progress conv=fsync` (или Balena Etcher / Armbian Imager).
2. Вставить флешку в Orange Pi One и включить.
3. При первом входе Armbian спросит только пароль root и пользователя — **ничего не доставляется**, всё уже внутри образа.

Размер образа после сборки ~3–5 GB — на карту 16 GB влезет, при желании потом можно расширить раздел через `armbian-config` → «Expand filesystem».

### SSH и OpenRouter сразу в образе

При сборке можно передать ключи — они попадут в образ, и после загрузки ничего доп. настраивать не нужно.

#### SSH

- В образ уже ставится и включается **openssh-server** (сервис `ssh`, порт 22). После загрузки Orange Pi демон поднимается сам.
- **Вход по ключу:** если при сборке задать `ROOT_SSH_AUTHORIZED_KEYS` (твой публичный ключ), он записывается в `/root/.ssh/authorized_keys`. Тогда заходишь без пароля: `ssh root@<IP>`. Пароль root при этом остаётся для консоли (и для входа по паролю, если не включён только ключ).
- Если ключ **не** передавали — вход по паролю (тот, что задал при первом запуске Armbian). При переданном ключе в образе выставляется `PermitRootLogin prohibit-password` (вход root только по ключу; при желании потом можно сменить в `/etc/ssh/sshd_config`).
- **Узнать IP:** с консоли/монитора — `ip a` или `hostname -I`; с хоста — сканер сети или роутер (список DHCP).

#### OpenRouter (ZeroClaw)

- Если при сборке задать **OPENROUTER_API_KEY**, в образе создаётся `/root/.zeroclaw/config.toml` с `default_provider = "openrouter"`. После загрузки можно сразу запускать `zeroclaw agent`.

Пример (одной строкой или экспортами):

```bash
export ROOT_SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)"
export OPENROUTER_API_KEY="sk-or-v1-..."
./build-image.sh
```

Или в одну строку:  
`ROOT_SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" OPENROUTER_API_KEY="sk-or-..." ./build-image.sh`

Ключи в образ попадают только в нужные файлы (authorized_keys и config.toml), в лог сборки не выводятся.

**Опционально тулчейны (два варианта, можно попробовать какой лучше):**
- **Pico** (RP2040 / Raspberry Pi Pico): `PROVISION_PICO=1 ./build-image.sh` — ставит cmake, gcc-arm-none-eabi, libnewlib-arm-none-eabi.
- **Nano** (AVR / Arduino Nano): `PROVISION_NANO=1 ./build-image.sh` — ставит gcc-avr, avrdude.
Можно передать оба: `PROVISION_PICO=1 PROVISION_NANO=1 ./build-image.sh`.

---

## 1. Образ Armbian (если собираешь вручную)

- Зайди на [armbian.com/orange-pi-one](https://www.armbian.com/orange-pi-one/) (или свою модель: Orange Pi 5, 5 Plus и т.д.).
- Скачай **Minimal** образ (Ubuntu 24.04 или Debian — как тебе удобнее). Либо используй **Armbian Imager**: выбираешь плату → образ → флешка → запись.

**Важно:** Orange Pi One — 32-bit (armhf). Orange Pi 5 и новее — 64-bit (arm64). Скрипт ниже по архитектуре сам подставит нужные пакеты.

---

## 2. Запись образа на флешку

- Через **Armbian Imager** (рекомендуется) или `dd`/Balena Etcher.
- После записи **не вытаскивай флешку** — смонтируй второй раздел (обычно это корень ОС).

Пример (подставь свой диск, например `/dev/sdb2`):

```bash
# Узнай раздел: lsblk
sudo mkdir -p /mnt/armbian
sudo mount /dev/sdX2 /mnt/armbian
```

---

## 3. Автологин и пароль (по желанию)

Чтобы первый запуск был без вопросов (пароль root, пользователь и т.д.), в корне образа можно заранее положить конфиг первого запуска.

Создай файл **на своей машине**, потом скопируй его в образ:

```bash
# На своей машине
nano firstboot.conf
```

Содержимое (подставь свои значения):

```bash
# Сохрани как /root/.not_logged_in_yet на смонтированном образе
PRESET_ROOT_PASSWORD="твой_пароль_root"
PRESET_USER_NAME="orangepi"
PRESET_USER_PASSWORD="твой_пароль"
PRESET_USER_SHELL="bash"
PRESET_LOCALE="ru_RU.UTF-8"
PRESET_TIMEZONE="Europe/Moscow"
```

Копирование в образ:

```bash
sudo cp firstboot.conf /mnt/armbian/root/.not_logged_in_yet
```

Если не делаешь автоконфиг — при первом включении Armbian спросит пароль и пользователя сам.

---

## 4. Скрипт установки всего софта (provisioning)

Armbian один раз после первого успешного входа (консоль или SSH) выполняет скрипт **`/root/provisioning.sh`**. Туда и кладём установку Python, Node, Go и при желании Pico-тулз.

На своей машине:

```bash
# Скопируй в проект готовый скрипт (он лежит в этом репо как provisioning.sh)
sudo cp /path/to/orange/provisioning.sh /mnt/armbian/root/provisioning.sh
sudo chmod +x /mnt/armbian/root/provisioning.sh
```

Размонтируй:

```bash
sudo umount /mnt/armbian
```

Вставляешь флешку в Orange Pi, включаешь — первый вход (логин/пароль по конфигу или введёшь вручную). После входа скрипт запустится сам и поставит всё нужное.

---

## 5. Что ставит provisioning.sh

| Компонент | Как ставится |
|-----------|----------------|
| **SSH** | `openssh-server`, сервис включён; при передаче `ROOT_SSH_AUTHORIZED_KEYS` — ключ в `/root/.ssh/authorized_keys`, вход `ssh root@<IP>`. См. раздел «SSH» выше. |
| **Python** | `python3`, `python3-pip`, `python3-venv` из apt |
| **Node.js** | NodeSource (LTS 20) для arm64; для 32-bit — бинарник armv7l с nodejs.org |
| **Go** | Официальный тарбол с go.dev под твою архитектуру |
| **Rust** | rustup + cargo (stable) в `/opt/rustup`, `/opt/cargo`; PATH через `/etc/profile.d/rust.sh` |
| **ZeroClaw** | [zeroclaw-labs/zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) — пребилд с GitHub Releases (aarch64 / armv7 / x86_64), ставится в `/usr/local/bin/zeroclaw` |
| **Pico / Nano** | Опционально при сборке: `PROVISION_PICO=1` — тулчейн RP2040 (Raspberry Pi Pico); `PROVISION_NANO=1` — AVR (Arduino Nano). Можно включить один или оба, посмотреть какой удобнее. |

ZeroClaw — лёгкий Rust-рантайм для AI-агентов («деплой где угодно, подменяй что угодно»). После установки: `zeroclaw onboard`, `zeroclaw agent`, `zeroclaw daemon` и т.д. Документация: [zeroclawlabs.ai](https://zeroclawlabs.ai), [docs в репо](https://github.com/zeroclaw-labs/zeroclaw/tree/master/docs).

---

## 6. Проверка после первого запуска

После выполнения provisioning (минута–несколько в зависимости от сети):

```bash
python3 --version
node --version
go version
cargo --version
zeroclaw --version
```

Если что-то не установилось — смотри лог в консоли или `/var/log` (скрипт пишет в stdout).

### ZeroClaw: первый запуск

1. **Настройка (один раз):**  
   `zeroclaw onboard --api-key sk-... --provider openrouter`  
   или интерактивно: `zeroclaw onboard --interactive`  
   Конфиг: `~/.zeroclaw/config.toml`.

2. **Чат:**  
   `zeroclaw agent -m "Hello"` или `zeroclaw agent` (интерактивно).

3. **Демон / каналы (Telegram и т.д.):**  
   `zeroclaw daemon` или `zeroclaw service install` + `zeroclaw service start`.

---

## Краткий чеклист

**Вариант «готовый образ»:**  
`./build-image.sh` → записать `orange-pi-one-ready.img` на флешку 16 GB → загрузка с Orange Pi — всё уже установлено.

**Вариант «ручная подготовка»:**  
1. Скачать Armbian Minimal под свою Orange Pi.  
2. Записать образ на флешку, смонтировать второй раздел.  
3. (Опционально) положить `firstboot.conf` как `/root/.not_logged_in_yet`.  
4. Положить `provisioning.sh` в `/root/`, `chmod +x`.  
5. Размонтировать, загрузиться — при первом входе скрипт доустановит софт.

Готовую флешку можно клонировать (dd или образ), чтобы не настраивать заново.
