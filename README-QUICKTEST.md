# Quick Test Guide — mlx-to-isolated-hermes

Эта инструкция для быстрой проверки всего стека на своей машине.

## Требования

- Apple Silicon Mac (M1/M2/M3/M4)
- LM Studio установлен и запущен **хотя бы один раз** (чтобы инициализировать `lms` CLI)
- Хотя бы одна MLX-модель (формат `safetensors`) скачана в LM Studio
- Интернет для первоначальной установки пакетов

---

## Вариант A — Интерактивный мастер (рекомендуется)

```bash
git clone git@github.com:aarogozin/mlx-to-isolated-hermes.git
cd mlx-to-isolated-hermes
make setup
```

Мастер сам:
1. Установит все зависимости через Homebrew (если нужно)
2. Предложит выбрать backend: **Multipass VM** / VMware Fusion VM / Docker
3. Настроит API-ключ и (опционально) Telegram-бота
4. Запросит выбор модели из каталога LM Studio
5. Развернёт весь стек и покажет URL Dashboard + статус Telegram

---

## Вариант B — Пошагово вручную

```bash
# 1. Bootstrap (Homebrew, oMLX, LM Studio CLI, Docker, Multipass)
make bootstrap

# 2. Проверка системы
make doctor

# 3. Просмотр скачанных моделей
make models-list

# 4. Синхронизация модели и выбор активной
make model-select

# 5. Запуск oMLX в фоне (launchd, переживает перезагрузку)
make model-start-bg

# 6. Создание VM-сандбокса (Multipass, ~5 мин)
make vm-create

# 7. Установка Hermes в VM + синхронизация модели
make e2e-ready

# 8. SSH в VM и запуск агента
make vm-ssh
# Внутри VM:
hermes
```

---

## Docker (preview)

```bash
# Сборка образа
make docker-build

# Создание контейнера и запуск
make docker-create
make docker-start

# Шелл в контейнере
make docker-shell
# Внутри:
hermes
```

---

## Hermes Dashboard

```bash
# Запуск (SSH-туннель из VM → localhost:9119)
make dashboard-start

# Открыть в браузере
make dashboard-open
# → http://127.0.0.1:9119
```

---

## Telegram Gateway (опционально)

```bash
# Создай бота у @BotFather, добавь в .env:
# TELEGRAM_BOT_TOKEN=...
# TELEGRAM_USER_ID=...  (получить у @userinfobot)

make telegram-start
make telegram-status
```

---

## Проверочные команды

```bash
make doctor                  # полная диагностика системы
make vm-status               # состояние VM и IP
make model-check             # проверка доступности oMLX API
make release-check           # финальная проверка перед релизом
SKIP_VM_E2E=1 SKIP_DOCKER_E2E=1 make release-check  # быстрая
```

---

## Смена модели

```bash
# Интерактивно
make model-select

# Не-интерактивно
MODEL=qwen3.6-27b-ud-mlx make model-select

# Влиять на авто-выбор модели при синхронизации
MODEL_DEFAULT_STRATEGY=largest-tool make models-sync  # default
MODEL_DEFAULT_STRATEGY=smallest-tool make models-sync # оригинальное поведение
```

---

## Docker Image из GHCR (CI-сборка)

```bash
# Получить образ собранный CI
docker pull ghcr.io/aarogozin/mlx-to-isolated-hermes:main

# Запустить вручную
docker run --rm -it --platform linux/arm64 \
  ghcr.io/aarogozin/mlx-to-isolated-hermes:main \
  /opt/hermes/.venv/bin/hermes --help
```

---

## Структура проекта

```
scripts/
  setup.sh              ← интерактивный мастер (ГЛАВНАЯ ТОЧКА ВХОДА)
  vm-common.sh          ← общие VM-хелперы (Multipass + VMware Fusion)
  bootstrap-macos.sh    ← установка зависимостей
  model-*.sh            ← управление oMLX
  vm-*.sh               ← управление VM
  docker-*.sh           ← управление Docker
  dashboard-control.sh  ← управление Dashboard
  telegram-control.sh   ← управление Telegram-гейтвеем
  doctor.sh             ← диагностика системы
docker/
  Dockerfile            ← образ Hermes для ARM64
.github/workflows/
  docker.yml            ← CI: build + push → ghcr.io
  release.yml           ← CI: GitHub Release по тегу v*
```
