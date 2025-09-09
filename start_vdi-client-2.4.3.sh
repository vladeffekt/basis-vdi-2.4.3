#!/bin/bash

# Настройки
CONTAINER_NAME="basis-vdi-2.4.3"
IMAGE_NAME="basis-vdi-client:2.4.3"
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
LOG_FILE="$SCRIPT_DIR/basis-vdi-client.log"

# Путь к конфигу
CONFIG_DIR="$SCRIPT_DIR/basis-config"
APP_CONFIG="$CONFIG_DIR/app-config"

# Функция для вывода в терминал и в лог
log_status() {
    echo "[$(date '+%H:%M:%S')] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Функция для отображения справки
show_usage() {
    echo "Использование: $0 [--broker <адрес_брокера>]"
    echo "  --broker Адрес VDI брокера (обязательный параметр)"
    echo "  --help   Показать эту справку"
    echo ""
    echo "Пример: $0 --broker sz-vpn.vdi.rt.gslb"
    exit 1
}

# Очистка старого лога
echo "========================================" > "$LOG_FILE"
log_status "Запуск скрипта"

# Парсинг аргументов командной строки
BROKER_ADDRESS=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --broker)
            BROKER_ADDRESS="$2"
            shift 2
            ;;
        --help)
            show_usage
            ;;
        *)
            echo "Неизвестный параметр: $1"
            show_usage
            ;;
    esac
done

# Проверка что брокер указан
if [ -z "$BROKER_ADDRESS" ]; then
    echo "Ошибка: Не указан адрес брокера"
    show_usage
fi

log_status "Используется брокер: $BROKER_ADDRESS"

# Проверка поднят ли tunsnx
log_status "Проверка состояния интерфейса tunsnx"
if ip link show tunsnx &>/dev/null && ip link show tunsnx | grep -q "UP"; then
    log_status "Интерфейс tunsnx активен"
else
    log_status "Ошибка: интерфейс tunsnx не подключён"
    echo "Ошибка: tunsnx не подключён. Подключитесь к корпоративному VPN и повторите попытку."
    exit 1
fi

# Удаляем старый контейнер 
if docker ps -a -q -f name=^${CONTAINER_NAME}$ | grep -q .; then
    log_status "Остановка старого контейнера"
    docker stop "$CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" > /dev/null 2>&1
fi

# Разрешить доступ к X-серверу 
log_status "Разрешение доступа к X-серверу"
xhost +local:docker > /dev/null 2>&1

# Получаем DNS-серверы из /etc/resolv.conf 
log_status "Поиск DNS-серверов в /etc/resolv.conf"
DNS_SERVERS=()
while IFS= read -r line; do
    if [[ "$line" =~ ^nameserver[[:space:]]+([0-9.]+) ]]; then
        dns="${BASH_REMATCH[1]}"
        if [[ "$dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if [[ "$dns" != "127.0.0.53" && "$dns" != "127.0.0.1" ]]; then
                DNS_SERVERS+=("$dns")
                log_status "Найден DNS: $dns"
            fi
        fi
    fi
done < /etc/resolv.conf

if [ ${#DNS_SERVERS[@]} -eq 0 ]; then
    log_status "Ошибка: не найдено ни одного DNS-сервера в /etc/resolv.conf"
    echo "Ошибка: не найдены DNS-серверы. Убедитесь, что tunsnx подключён и /etc/resolv.conf содержит актуальные nameserver."
    exit 1
fi

# Проверка и загрузка образа
log_status "Проверка наличия образа: $IMAGE_NAME"
if docker images -q "$IMAGE_NAME" > /dev/null 2>&1; then
    log_status "Образ найден локально"
else
    log_status "Образ не найден. Начинаю загрузку..."
    echo  # Чтобы прогресс docker pull был виден
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

# Формируем аргументы --dns
DNS_ARGS=""
for dns in "${DNS_SERVERS[@]}"; do
    DNS_ARGS="$DNS_ARGS --dns $dns"
done

# Создаём директорию для конфига, если её нет
mkdir -p "$CONFIG_DIR"


SHARE_DIR="/home/$USER/$SCRIPT_DIR/share_dir"
mkdir -p "$CONFIG_DIR"
# Создаём конфиг с переданным адресом брокера
log_status "Создаём конфиг-файл с брокером: $BROKER_ADDRESS"
cat > "$APP_CONFIG" << EOF
{
  "AutoConnect": false,
  "brokers": ["$BROKER_ADDRESS"],
  "rdp_client_path": "/usr/bin/xfreerdp",
  "stream_width": 0,
  "stream_height": 0,
  "xfreerdp_new_style_args": true,
  "remote_sound_mode": 0,
  "create_samba_shares": true,
  "samba_printers": false,
  "store_pin_code": true,
  "log_level": "INFO",
  "log_timezone": "Europe/Moscow",
  "rdp_client_extra_args": [
    "/clipboard"
  ],
  "samba_shares": [
    {
      "name": "share_dir",
      "path": "set_your_path",
      "read_only": false
    }
  ]
}
EOF

log_status "Конфиг-файл создан: $APP_CONFIG"

# Определяем временную зону хоста 
HOST_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Europe/Moscow")
log_status "Используем временную зону хоста: $HOST_TIMEZONE"

# Проверка наличия PipeWire socket
PULSE_USER_DIR="/run/user/$(id -u)/pulse"
if [ -S "$PULSE_USER_DIR/native" ]; then
    log_status "Найден PipeWire socket: $PULSE_USER_DIR/native"
else
    log_status "Предупреждение: сокет PipeWire не найден. Убедитесь, что pipewire-pulse запущен."
fi

# Определяем доступные HID-устройства 
HID_DEVICES=()
for dev in /dev/usb/hiddev[0-9]*; do
    if [ -e "$dev" ]; then
        HID_DEVICES+=("$dev")
        log_status "Найдено HID-устройство: $dev"
    fi
done

if [ ${#HID_DEVICES[@]} -eq 0 ]; then
    log_status "Предупреждение: не найдено ни одного /dev/usb/hiddev* устройство. Работа с токенами может быть нарушена."
fi

# Формируем аргументы --device для HID
HID_ARGS=""
for dev in "${HID_DEVICES[@]}"; do
    HID_ARGS="$HID_ARGS --device $dev"
done

# Проверка существования директории /run/user/UID 
USER_RUNTIME_DIR="/run/user/$(id -u)"
if [ -d "$USER_RUNTIME_DIR" ]; then
    USER_RUNTIME_ARG="-v $USER_RUNTIME_DIR:/run/user/host:ro"
else
    log_status "Предупреждение: Директория $USER_RUNTIME_DIR не существует на хосте."
    USER_RUNTIME_ARG=""
fi

# Запуск с пробросом конфига и звука 
log_status "Запуск контейнера в фоне: $CONTAINER_NAME"

# Запускаем docker run напрямую в фоне
nohup docker run \
  --name "$CONTAINER_NAME" \
  --network host \
  $DNS_ARGS \
  -d \
  --tmpfs /tmp/runtime-vdi:rw,mode=700,uid=0,gid=0 \
  -e DISPLAY \
  -e XDG_RUNTIME_DIR="/tmp/runtime-vdi" \
  -e TZ="$HOST_TIMEZONE" \
  -v /etc/timezone:/etc/timezone:ro \
  -v /etc/localtime:/etc/localtime:ro \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v /tmp:/tmp \
  -v /dev/bus/usb:/dev/bus/usb \
  -v /run/user/$(id -u)/bus:/run/user/host/bus \
  $USER_RUNTIME_ARG \
  $HID_ARGS \
  -v "$CONFIG_DIR:/root/.vdi-client" \
  "$IMAGE_NAME" \
  /bin/sh -c "
    echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Запуск desktop-agent-linux\" >> /tmp/container.log
    /opt/vdi-client/bin/desktop-agent-linux > /tmp/agent.log 2>&1 &
    sleep 3  # <-- Ждём 3 секунды, чтобы агент успел запуститься
    if [ ! -S /tmp/wp_desktop_agent.sock ]; then
        echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Ошибка: сокет агента не создан\" >> /tmp/container.log
        exit 1
    fi
    echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Сокет агента создан\" >> /tmp/container.log
    echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] Запуск desktop-client\" >> /tmp/container.log
    exec /opt/vdi-client/bin/desktop-client
  " >> "$LOG_FILE" 2>&1 &

echo
echo "Контейнер '$CONTAINER_NAME' запущен в фоне."
echo "Логи пишутся в: $LOG_FILE"
echo "Для просмотра: tail -f '$LOG_FILE'"
echo "Для остановки: docker stop $CONTAINER_NAME"
echo "Терминал можно закрыть — клиент продолжит работать."
