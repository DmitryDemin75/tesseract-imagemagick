#!/bin/bash
# ha_meter.sh
# Минимальные улучшения устойчивости: таймауты curl, проверка файла, без пустых логов.
# Поддержка опций из /data/options.json, если аддон запущен в Home Assistant.

###############################################################################
# Настройки отладки и функций логирования
###############################################################################
DEBUG=1  # Установите в 1 для включения отладочных сообщений

log_debug() {
  if [ "$DEBUG" -eq 1 ]; then
    echo "[DEBUG] $1"
  fi
}

log_error() {
  echo "[ERROR] $1" >&2
}

###############################################################################
# Основные настройки (значения по умолчанию)
###############################################################################
SCRIPT_DIR=$(dirname "$0")

# URL для получения скриншота с камеры
CAMERA_URL="http://192.168.8.195/cgi-bin/CGIProxy.fcgi?cmd=snapPicture2&usr=admin&pwd=t1010113"

# MQTT-настройки
MQTT_HOST="192.168.8.20"
MQTT_USER="mqtt"
MQTT_PASSWORD="mqtt"

# Топики для публикации состояния для каждого сенсора
MQTT_TOPIC_1="homeassistant/sensor/energy_meter/1_8_0/state"
MQTT_TOPIC_2="homeassistant/sensor/energy_meter/2_8_0/state"

# Топики для конфигурации MQTT Discovery
MQTT_CONFIG_TOPIC_1="homeassistant/sensor/energy_meter_1_8_0/config"
MQTT_CONFIG_TOPIC_2="homeassistant/sensor/energy_meter_2_8_0/config"

# Интервалы (сек)
SLEEP_INTERVAL=1    # Основной интервал между итерациями
EXTRA_PAUSE=100     # Дополнительная пауза после публикации/прохождения серии вокруг 2.8.0

# Координаты обрезки (фиксированные для обоих кодов)
CODE_CROP="64x23+576+361"
VALUE_CROP="134x30+670+353"

###############################################################################
# Загрузка опций из /data/options.json (если аддон запущен в HA)
###############################################################################
OPTS_FILE="/data/options.json"
if [ -f "$OPTS_FILE" ] && command -v jq >/dev/null 2>&1; then
  get_opt() { jq -er "$1 // empty" "$OPTS_FILE" 2>/dev/null; }

  v="$(get_opt '.camera_url')";     [ -n "$v" ] && CAMERA_URL="$v"
  v="$(get_opt '.mqtt_host')";      [ -n "$v" ] && MQTT_HOST="$v"
  v="$(get_opt '.mqtt_user')";      [ -n "$v" ] && MQTT_USER="$v"
  v="$(get_opt '.mqtt_password')";  [ -n "$v" ] && MQTT_PASSWORD="$v"
  v="$(get_opt '.sleep_interval')"; [ -n "$v" ] && SLEEP_INTERVAL="$v"
  v="$(get_opt '.extra_pause')";    [ -n "$v" ] && EXTRA_PAUSE="$v"
  v="$(get_opt '.code_crop')";      [ -n "$v" ] && CODE_CROP="$v"
  v="$(get_opt '.value_crop')";     [ -n "$v" ] && VALUE_CROP="$v"
  v="$(get_opt '.debug')"
  if [ -n "$v" ]; then
    case "$v" in
      true|True|1|"\"true\"" ) DEBUG=1 ;;
      false|False|0|"\"false\"" ) DEBUG=0 ;;
      * ) DEBUG=1 ;;
    esac
  fi
fi

log_debug "Опции загружены. CAMERA_URL=<hidden>, CODE_CROP=$CODE_CROP, VALUE_CROP=$VALUE_CROP, DEBUG=$DEBUG, SLEEP_INTERVAL=$SLEEP_INTERVAL, EXTRA_PAUSE=$EXTRA_PAUSE"

###############################################################################
# Публикация конфигурационных сообщений для MQTT Discovery (retained)
###############################################################################
config_payload_1='{
  "name": "Energy Meter 1.8.0",
  "state_topic": "homeassistant/sensor/energy_meter/1_8_0/state",
  "unique_id": "energy_meter_1_8_0",
  "unit_of_measurement": "kWh",
  "value_template": "{{ value_json.value }}",
  "json_attributes_topic": "homeassistant/sensor/energy_meter/1_8_0/state"
}'
config_payload_2='{
  "name": "Energy Meter 2.8.0",
  "state_topic": "homeassistant/sensor/energy_meter/2_8_0/state",
  "unique_id": "energy_meter_2_8_0",
  "unit_of_measurement": "kWh",
  "value_template": "{{ value_json.value }}",
  "json_attributes_topic": "homeassistant/sensor/energy_meter/2_8_0/state"
}'

log_debug "Публикация конфигурационных сообщений для MQTT Discovery..."
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_1" -m "$config_payload_1" || log_error "Ошибка публикации конфигурации для 1.8.0"
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_2" -m "$config_payload_2" || log_error "Ошибка публикации конфигурации для 2.8.0"

###############################################################################
# Основной цикл
###############################################################################
while true; do
  # Скачивание скриншота (надёжно: таймауты + фатальные коды)
  curl -fsS --connect-timeout 5 --max-time 7 -o "$SCRIPT_DIR/full.jpg" "$CAMERA_URL"
  if [ $? -ne 0 ] || [ ! -s "$SCRIPT_DIR/full.jpg" ]; then
    log_error "Ошибка скачивания скриншота с камеры."
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  # Определение DPI (информативно, но оставляем как у вас)
  RAW_DPI=$(identify -format "%x" "$SCRIPT_DIR/full.jpg" 2>/dev/null || echo "")
  DPI=$(echo "$RAW_DPI" | sed 's/[^0-9.]//g')
  if [ -z "$DPI" ] || [ "$DPI" = "0" ]; then
    DPI=300
  fi

  # КОД: обрезка
  convert -density "$DPI" -units PixelsPerInch "$SCRIPT_DIR/full.jpg" -crop "$CODE_CROP" +repage "$SCRIPT_DIR/code.jpg"
  if [ $? -ne 0 ]; then
    log_error "Ошибка обрезки области с кодом."
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  # OCR кода (whitelist: цифры + точка)
  code=$(tesseract "$SCRIPT_DIR/code.jpg" stdout \
    -l ssd_int --tessdata-dir "$SCRIPT_DIR" --psm 7 \
    -c tessedit_char_whitelist=0123456789.)
  if [ $? -ne 0 ]; then
    log_error "Ошибка OCR для кода."
    sleep "$SLEEP_INTERVAL"
    continue
  fi
  code=$(echo "$code" | xargs)
  log_debug "Распознан код: '$code'"

  # Нормализация узкого кейса: '18.0' -> '1.8.0' (ваше правило)
  if [ "$code" = "1.8.0" ] || [ "$code" = "18.0" ]; then
    code="1.8.0"
  fi

  published=0

  # Обрабатываем только 1.8.0 и 2.8.0
  if [ "$code" = "1.8.0" ] || [ "$code" = "2.8.0" ]; then
    # VALUE: обрезка
    convert -density "$DPI" -units PixelsPerInch "$SCRIPT_DIR/full.jpg" -crop "$VALUE_CROP" +repage "$SCRIPT_DIR/value.jpg"
    if [ $? -ne 0 ]; then
      log_error "Ошибка обрезки области со значением."
      sleep "$SLEEP_INTERVAL"
      continue
    fi

    # OCR значения (оставляю ваш whitelist без '4', как вы и хотели)
    value=$(tesseract "$SCRIPT_DIR/value.jpg" stdout \
      -l ssd_int --tessdata-dir "$SCRIPT_DIR" --psm 7 \
      -c tessedit_char_whitelist=012356789)
    if [ $? -ne 0 ]; then
      log_error "Ошибка OCR для значения."
      sleep "$SLEEP_INTERVAL"
      continue
    fi
    value=$(echo "$value" | xargs)

    # Удаляем ведущие нули
    value=$(echo "$value" | sed 's/^0*//')
    if [ -z "$value" ]; then
      value="0"
    fi

    timestamp=$(date --iso-8601=seconds)
    payload=$(printf '{"code": "%s", "value": "%s", "timestamp": "%s"}' "$code" "$value" "$timestamp")

    if [ "$code" = "1.8.0" ]; then
      log_debug "Публикация MQTT для кода 1.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "$MQTT_TOPIC_1" -m "$payload" || log_error "Ошибка публикации данных для 1.8.0."
      published=1

    elif [ "$code" = "2.8.0" ]; then
      log_debug "Публикация MQTT для кода 2.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "$MQTT_TOPIC_2" -m "$payload" || log_error "Ошибка публикации данных для 2.8.0."
      published=1
    fi

  else
    # Не логируем пустую строку — просто пропускаем
    :
  fi

  # Особенность вашего счётчика: «132.8.0» следует за «2.8.0» — используем это как маркер
  if [ "$code" = "132.8.0" ]; then
    published=2
  fi

  # Логика задержек
  if [ $published -eq 0 ]; then
    sleep "$SLEEP_INTERVAL"
  elif [ $published -eq 2 ]; then
    log_debug "Ожидаем '$EXTRA_PAUSE' сек и идём дальше..."
    sleep "$EXTRA_PAUSE"
  fi
done
