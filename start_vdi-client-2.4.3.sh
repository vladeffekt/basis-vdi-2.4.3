#!/bin/bash

# Настройки
CONTAINER_NAME="basis-vdi"
IMAGE_NAME="basis-vdi-client:2.4.3-optimized"
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
LOG_FILE="$SCRIPT_DIR/basis-vdi-client.log"

# Путь к конфигу
CONFIG_DIR="$HOME/Basis/basis-config"
SHARE_DIR="$HOME/Basis/share_dir"

# Функция для вывода в терминал и в лог
log_status() {
    echo "[$(date '+%H:%M:%S')] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Очистка старого лога
echo "========================================" > "$LOG_FILE"
log_status "Запуск скрипта"

# Удаляем старый контейнер
if docker ps -a -q -f name=^${CONTAINER_NAME}$ | grep -q .; then
    log_status "Остановка старого контейнера"
    docker stop "$CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" > /dev/null 2>&1
fi

# Разрешить доступ к X-серверу
log_status "Разрешение доступа к X-серверу"
xhost +local:docker > /dev/null 2>&1 || log_status "Внимание: не удалось выполнить 'xhost +local:docker'"

# Получаем DNS-серверы из /etc/resolv.conf
log_status "Поиск DNS-серверов в /etc/resolv.conf"
DNS_SERVERS=()
while IFS= read -r line; do
    if [[ "$line" =~ ^nameserver[[:space:]]+([0-9.]+) ]]; then
        dns="${BASH_REMATCH[1]}"
        if [[ "$dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$dns" != "127.0.0.53" ]] && [[ "$dns" != "127.0.0.1" ]]; then
            DNS_SERVERS+=("$dns")
            log_status "Найден DNS: $dns"
        fi
    fi
done < /etc/resolv.conf

if [ ${#DNS_SERVERS[@]} -eq 0 ]; then
    log_status "Ошибка: не найдено ни одного DNS-сервера в /etc/resolv.conf"
    echo "Ошибка: не найдены DNS-серверы. Убедитесь, что tunsnx подключён."
    exit 1
fi

# Формируем аргументы --dns
DNS_ARGS=""
for dns in "${DNS_SERVERS[@]}"; do
    DNS_ARGS="$DNS_ARGS --dns $dns"
done

# Проверка и загрузка образа
log_status "Проверка наличия образа: $IMAGE_NAME"
if docker images -q "$IMAGE_NAME" > /dev/null 2>&1; then
    log_status "Образ найден локально"
else
    log_status "Образ не найден. Начинаю загрузку..."
    if docker pull "$IMAGE_NAME"; then
        log_status "Образ успешно загружен"
    else
        log_status "Ошибка: не удалось загрузить образ"
        echo "Ошибка: не удалось загрузить образ $IMAGE_NAME"
        exit 1
    fi
fi

# Пути
RUNTIME_DIR="/tmp/runtime-vdi"
AGENT_DIR="/tmp/.basis-vdi"
mkdir -p "$RUNTIME_DIR" && chmod 700 "$RUNTIME_DIR"
mkdir -p "$AGENT_DIR" && chmod 777 "$AGENT_DIR"

# Создаём директорию для конфига, если её нет
mkdir -p "$CONFIG_DIR"

# Создаём директорию для общего доступа
mkdir -p "$SHARE_DIR"
log_status "Директория для общего доступа готова: $SHARE_DIR"

# Определяем временную зону хоста
HOST_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Europe/Moscow")
log_status "Используем временную зону хоста: $HOST_TIMEZONE"

# Проверка наличия PipeWire/PulseAudio socket
PULSE_USER_DIR="/run/user/$(id -u)/pulse"
if [ -S "$PULSE_USER_DIR/native" ]; then
    log_status "Найден PulseAudio socket: $PULSE_USER_DIR/native"
else
    log_status "Внимание: сокет PulseAudio не найден. Звук может не работать. Убедитесь, что pipewire-pulse или pulseaudio запущен."
fi

# Определяем доступные HID-устройства
HID_ARGS=""
log_status "Сканирование HID-устройств (/dev/usb/hiddev*)..."
for dev in /dev/usb/hiddev[0-9]*; do
    if [ -e "$dev" ]; then
        HID_ARGS="$HID_ARGS --device $dev"
        log_status "Добавлено HID-устройство: $dev"
    fi
done

if [ -z "$HID_ARGS" ]; then
    log_status "Внимание: HID-устройства не найдены. Работа с токенами может быть нарушена."
fi

# Проверка существования директории /run/user/UID
USER_RUNTIME_DIR="/run/user/$(id -u)"
USER_RUNTIME_ARG=""
if [ -d "$USER_RUNTIME_DIR" ]; then
    USER_RUNTIME_ARG="-v $USER_RUNTIME_DIR:/run/user/host:ro"
    log_status "Директория пользователя найдена: $USER_RUNTIME_DIR"
else
    log_status "Внимание: директория $USER_RUNTIME_DIR не существует на хосте."
fi

# Запуск контейнера в фоне
log_status "Запуск контейнера в фоне: $CONTAINER_NAME"

DOCKER_RUN_CMD="docker run \
  --name '$CONTAINER_NAME' \
  --network host \
  $DNS_ARGS \
  -e DISPLAY \
  -e XDG_RUNTIME_DIR='$RUNTIME_DIR' \
  -e TZ='$HOST_TIMEZONE' \
  -e QT_QUICK_BACKEND=software \
  -e QMLSCENE_DEVICE=softwarecontext \
  -e GDK_BACKEND=x11 \
  -e LIBGL_ALWAYS_SOFTWARE=1 \
  -e PULSE_SERVER=unix:/run/user/host/pulse/native \
  -e PULSE_COOKIE=/run/user/host/pulse/cookie \
  -v /etc/timezone:/etc/timezone:ro \
  -v /etc/localtime:/etc/localtime:ro \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v /tmp:/tmp \
  -v /dev/bus/usb:/dev/bus/usb \
  -v /run/user/$(id -u)/pulse:/run/user/host/pulse:ro \
  $USER_RUNTIME_ARG \
  $HID_ARGS \
  -v '$CONFIG_DIR':/root/.vdi-client \
  -v '$SHARE_DIR':/root/share \
  '$IMAGE_NAME' \
  /bin/sh -c '
    # Запускаем PulseAudio в фоне
    pulseaudio --start --daemonize --exit-idle-time=-1 > /tmp/pulseaudio.log 2>&1 &
    sleep 2
    echo \"[\$(date \\\"+%Y-%m-%d %H:%M:%S\\\")]\ Запуск\ desktop-agent-linux\" >> /tmp/container.log;
    /opt/vdi-client/bin/desktop-agent-linux --headless > /tmp/agent.log 2>&1 & \
    sleep 3; \
    echo \"[\$(date \\\"+%Y-%m-%d %H:%M:%S\\\")]\ Запуск\ desktop-client\" >> /tmp/container.log; \
    exec /opt/vdi-client/bin/desktop-client
  '"

# Запускаем в фоне
nohup sh -c "$DOCKER_RUN_CMD" >> "$LOG_FILE" 2>&1 &

# Финальное сообщение
echo
echo "Контейнер '$CONTAINER_NAME' запущен в фоне."
echo "Логи пишутся в: $LOG_FILE"
echo "Для просмотра в реальном времени: tail -f '$LOG_FILE'"
echo "Для остановки: docker stop $CONTAINER_NAME"
echo "Терминал можно закрыть — клиент продолжит работать."

log_status "Скрипт завершил инициализацию запуска."
