#!/bin/bash
# ha_meter.sh

###############################################################################
# Настройки отладки и функций логирования
###############################################################################
DEBUG=1  # по умолчанию; может быть переопределён из /data/options.json

log_debug() {
  if [ "$DEBUG" -eq 1 ]; then
    # в stdout — чтобы было видно в логе аддона
    echo "[DEBUG] $1"
  fi
}

log_error() {
  echo "[ERROR] $1" >&2
}

###############################################################################
# Основные настройки (дефолты; будут переопределены из /data/options.json)
###############################################################################
SCRIPT_DIR=$(dirname "$0")

# Камера
CAMERA_URL="http://192.168.8.195/cgi-bin/CGIProxy.fcgi?cmd=snapPicture2&usr=admin&pwd=t1010113"

# MQTT
MQTT_HOST="192.168.8.20"
MQTT_USER="mqtt"
MQTT_PASSWORD="mqtt"

# Топики
MQTT_TOPIC_1="homeassistant/sensor/energy_meter/1_8_0/state"
MQTT_TOPIC_2="homeassistant/sensor/energy_meter/2_8_0/state"

MQTT_CONFIG_TOPIC_1="homeassistant/sensor/energy_meter_1_8_0/config"
MQTT_CONFIG_TOPIC_2="homeassistant/sensor/energy_meter_2_8_0/config"

# Интервалы
SLEEP_INTERVAL=1
EXTRA_PAUSE=100

# Кропы
CODE_CROP="64x23+576+361"
VALUE_CROP="134x30+670+353"

###############################################################################
# Загрузка опций из /data/options.json (UI аддона)
###############################################################################
OPTS_FILE="/data/options.json"
if [ -f "$OPTS_FILE" ]; then
  # безопасный геттер: jq -r <expr> || пусто
  get_opt() { jq -er "$1 // empty" "$OPTS_FILE" 2>/dev/null; }

  v="$(get_opt '.camera_url')";       if [ -n "$v" ]; then CAMERA_URL="$v"; fi

  v="$(get_opt '.mqtt_host')";        if [ -n "$v" ]; then MQTT_HOST="$v"; fi
  v="$(get_opt '.mqtt_user')";        if [ -n "$v" ]; then MQTT_USER="$v"; fi
  v="$(get_opt '.mqtt_password')";    if [ -n "$v" ]; then MQTT_PASSWORD="$v"; fi

  v="$(get_opt '.sleep_interval')";   if [ -n "$v" ]; then SLEEP_INTERVAL="$v"; fi
  v="$(get_opt '.extra_pause')";      if [ -n "$v" ]; then EXTRA_PAUSE="$v"; fi

  v="$(get_opt '.code_crop')";        if [ -n "$v" ]; then CODE_CROP="$v"; fi
  v="$(get_opt '.value_crop')";       if [ -n "$v" ]; then VALUE_CROP="$v"; fi

  v="$(get_opt '.debug')"
  if [ -n "$v" ]; then
    # допускаем true/false/1/0
    case "$v" in
      true|True|1|"\"true\"" ) DEBUG=1 ;;
      false|False|0|"\"false\"" ) DEBUG=0 ;;
      * ) DEBUG=1 ;;
    esac
  fi
fi

log_debug "Опции загружены. CAMERA_URL=$CAMERA_URL, CODE_CROP=$CODE_CROP, VALUE_CROP=$VALUE_CROP, DEBUG=$DEBUG, SLEEP_INTERVAL=$SLEEP_INTERVAL, EXTRA_PAUSE=$EXTRA_PAUSE"

###############################################################################
# Публикация конфигурации MQTT Discovery (retained)
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

mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
  -t "$MQTT_CONFIG_TOPIC_1" -m "$config_payload_1" || log_error "Ошибка публикации конфигов для 1.8.0"

mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
  -t "$MQTT_CONFIG_TOPIC_2" -m "$config_payload_2" || log_error "Ошибка публикации конфигов для 2.8.0"

###############################################################################
# Основной цикл (ВАША рабочая логика без изменений)
###############################################################################
while true; do
  # Скачивание кадра
  curl -s -o "$SCRIPT_DIR/full.jpg" "$CAMERA_URL"
  if [ $? -ne 0 ]; then
    log_error "Ошибка скачивания скриншота с камеры."
    sleep "$SLEEP_INTERVAL"
    continue
  fi
  if [ ! -f "$SCRIPT_DIR/full.jpg" ]; then
    log_error "Файл скриншота не найден."
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  # DPI
  RAW_DPI=$(identify -format "%x" "$SCRIPT_DIR/full.jpg" 2>/dev/null || echo "")
  DPI=$(echo "$RAW_DPI" | sed 's/[^0-9.]//g')
  if [ -z "$DPI" ] || [ "$DPI" = "0" ]; then
    DPI=300
  fi

  # КОД: кроп
  convert -density "$DPI" -units PixelsPerInch "$SCRIPT_DIR/full.jpg" -crop "$CODE_CROP" +repage "$SCRIPT_DIR/code.jpg"
  if [ $? -ne 0 ]; then
    log_error "Ошибка обрезки области с кодом."
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  # OCR кода
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

  # Нормализация «18.0» -> «1.8.0»
  if [ "$code" = "1.8.0" ] || [ "$code" = "18.0" ]; then
    code="1.8.0"
  fi

  published=0

  # Только интересные коды
  if [ "$code" = "1.8.0" ] || [ "$code" = "2.8.0" ]; then
    # VALUE: кроп
    convert -density "$DPI" -units PixelsPerInch "$SCRIPT_DIR/full.jpg" -crop "$VALUE_CROP" +repage "$SCRIPT_DIR/value.jpg"
    if [ $? -ne 0 ]; then
      log_error "Ошибка обрезки области со значением."
      sleep "$SLEEP_INTERVAL"
      continue
    fi

    # OCR значения
    value=$(tesseract "$SCRIPT_DIR/value.jpg" stdout \
      -l ssd_int --tessdata-dir "$SCRIPT_DIR" --psm 7 \
      -c tessedit_char_whitelist=012356789)
    if [ $? -ne 0 ]; then
      log_error "Ошибка OCR для значения."
      sleep "$SLEEP_INTERVAL"
      continue
    fi
    value=$(echo "$value" | xargs)

    # Убираем лидирующие нули
    value=$(echo "$value" | sed 's/^0*//')
    if [ -z "$value" ]; then
      value="0"
    fi

    timestamp=$(date --iso-8601=seconds)
    payload=$(printf '{"code": "%s", "value": "%s", "timestamp": "%s"}' "$code" "$value" "$timestamp")

    if [ "$code" = "1.8.0" ]; then
      log_debug "Публикация MQTT для кода 1.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_TOPIC_1" -m "$payload" || log_error "Ошибка публикации 1.8.0"
      published=1
    elif [ "$code" = "2.8.0" ]; then
      log_debug "Публикация MQTT для кода 2.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_TOPIC_2" -m "$payload" || log_error "Ошибка публикации 2.8.0"
      published=1
    fi
  else
    # «не наш» код — молчим (оставляю пустой лог как у тебя)
    log_debug ""
  fi

  # Хак с "132.8.0" оставляю как у тебя
  if [ "$code" = "132.8.0" ]; then
    published=2
  fi

  # Задержки
  if [ $published -eq 0 ]; then
    sleep "$SLEEP_INTERVAL"
  elif [ $published -eq 2 ]; then
    log_debug "Ожидаем '$EXTRA_PAUSE'сек и идем дальше..."
    sleep "$EXTRA_PAUSE"
  fi
done
