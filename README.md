# Orange Pi + Armbian: образ «всё сразу»

Схема: ставишь Armbian на флешку, кладёшь на неё скрипт первого запуска — при первом входе доустанавливаются Python, Node, Go и (опционально) тулзы для Pico. Дальше загружаешься уже с готовой системы.

---

## 1. Образ Armbian

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
| **Python** | `python3`, `python3-pip`, `python3-venv` из apt |
| **Node.js** | NodeSource (LTS 20) для arm64; для 32-bit — бинарник armv7l с nodejs.org |
| **Go** | Официальный тарбол с go.dev под твою архитектуру |
| **ZeroClaw** | [zeroclaw-labs/zeroclaw](https://github.com/zeroclaw-labs/zeroclaw) — пребилд с GitHub Releases (aarch64 / armv7 / x86_64), ставится в `/usr/local/bin/zeroclaw` |
| **Pico** | Опционально: раскомментировать в скрипте — picotool и зависимости под Raspberry Pi Pico |

ZeroClaw — лёгкий Rust-рантайм для AI-агентов («деплой где угодно, подменяй что угодно»). После установки: `zeroclaw onboard`, `zeroclaw agent`, `zeroclaw daemon` и т.д. Документация: [zeroclawlabs.ai](https://zeroclawlabs.ai), [docs в репо](https://github.com/zeroclaw-labs/zeroclaw/tree/master/docs).

---

## 6. Проверка после первого запуска

После выполнения provisioning (минута–несколько в зависимости от сети):

```bash
python3 --version
node --version
go version
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

1. Скачать Armbian Minimal под свою Orange Pi.
2. Записать образ на флешку.
3. Смонтировать второй раздел образа.
4. (Опционально) положить `firstboot.conf` как `/root/.not_logged_in_yet`.
5. Положить `provisioning.sh` в `/root/` и сделать исполняемым.
6. Размонтировать, загрузиться с флешки, один раз войти — дальше всё доустановится само.

Готовую флешку потом можно клонировать (dd или образ второго раздела), чтобы не настраивать заново.
