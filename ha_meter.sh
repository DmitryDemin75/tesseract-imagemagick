#!/bin/bash
# ha_meter.sh
# Добавлено: публикация ЕДИНОГО ROI (code+value) через MQTT Image Discovery при DEBUG=true.

###############################################################################
# Логирование
###############################################################################
DEBUG=1

log_debug() { if [ "$DEBUG" -eq 1 ]; then echo "[DEBUG] $*"; fi; }
log_error() { echo "[ERROR] $*" >&2; }

###############################################################################
# Дефолтные настройки (переопределяются из /data/options.json)
###############################################################################
SCRIPT_DIR=$(dirname "$0")

CAMERA_URL="http://192.168.8.195/cgi-bin/CGIProxy.fcgi?cmd=snapPicture2&usr=admin&pwd=t1010113"

MQTT_HOST="192.168.8.20"
MQTT_USER="mqtt"
MQTT_PASSWORD="mqtt"

MQTT_TOPIC_1="homeassistant/sensor/energy_meter/1_8_0/state"
MQTT_TOPIC_2="homeassistant/sensor/energy_meter/2_8_0/state"

MQTT_CONFIG_TOPIC_1="homeassistant/sensor/energy_meter_1_8_0/config"
MQTT_CONFIG_TOPIC_2="homeassistant/sensor/energy_meter_2_8_0/config"

SLEEP_INTERVAL=1
EXTRA_PAUSE=100

CODE_CROP="64x23+576+361"
VALUE_CROP="134x30+670+353"

# ОДИН топик/сущность для комбинированного изображения ROI
IMG_DISC_COMBINED="homeassistant/image/energy_meter_roi_combined/config"
IMG_TOPIC_COMBINED="homeassistant/energy_meter/roi/combined"  # бинарный JPEG

###############################################################################
# Загрузка опций из UI аддона
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
# MQTT Discovery: сенсоры (как было)
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

log_debug "Публикация конфигурационных сообщений для MQTT Discovery…"
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_1" -m "$config_payload_1" || log_error "Ошибка публикации конфигурации 1.8.0"
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_2" -m "$config_payload_2" || log_error "Ошибка публикации конфигурации 2.8.0"

###############################################################################
# MQTT Discovery: ЕДИНОЕ изображение ROI (включается при DEBUG=true)
###############################################################################
if [ "$DEBUG" -eq 1 ]; then
  img_conf_combined='{"name":"Energy Meter ROI (code+value)","unique_id":"energy_meter_roi_combined","image_topic":"'"$IMG_TOPIC_COMBINED"'","content_type":"image/jpeg"}'
  mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$IMG_DISC_COMBINED" -m "$img_conf_combined" || log_error "Ошибка публикации discovery ROI combined"
  log_debug "ROI (combined) discovery опубликован (DEBUG=true)."
fi

###############################################################################
# Основной цикл
###############################################################################
while true; do
  # Надёжное скачивание
  curl -fsS --connect-timeout 5 --max-time 7 -o "$SCRIPT_DIR/full.jpg" "$CAMERA_URL"
  if [ $? -ne 0 ] || [ ! -s "$SCRIPT_DIR/full.jpg" ]; then
    log_error "Ошибка скачивания скриншота с камеры."
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  # DPI (информативно)
  RAW_DPI=$(identify -format "%x" "$SCRIPT_DIR/full.jpg" 2>/dev/null || echo "")
  DPI=$(echo "$RAW_DPI" | sed 's/[^0-9.]//g'); [ -z "$DPI" ] && DPI=300

  # КОД: кроп
  convert -density "$DPI" -units PixelsPerInch "$SCRIPT_DIR/full.jpg" -crop "$CODE_CROP" +repage "$SCRIPT_DIR/code.jpg" || { log_error "Ошибка кропа CODE"; sleep "$SLEEP_INTERVAL"; continue; }

  # OCR кода
  code=$(tesseract "$SCRIPT_DIR/code.jpg" stdout -l ssd_int --tessdata-dir "$SCRIPT_DIR" --psm 7 -c tessedit_char_whitelist=0123456789.)
  [ $? -ne 0 ] && { log_error "Ошибка OCR CODE"; sleep "$SLEEP_INTERVAL"; continue; }
  code=$(echo "$code" | xargs)
  log_debug "Распознан код: '$code'"

  # Нормализация узкого кейса
  if [ "$code" = "1.8.0" ] || [ "$code" = "18.0" ]; then code="1.8.0"; fi

  published=0

  if [ "$code" = "1.8.0" ] || [ "$code" = "2.8.0" ]; then
    # VALUE: кроп
    convert -density "$DPI" -units PixelsPerInch "$SCRIPT_DIR/full.jpg" -crop "$VALUE_CROP" +repage "$SCRIPT_DIR/value.jpg" || { log_error "Ошибка кропа VALUE"; sleep "$SLEEP_INTERVAL"; continue; }

    # Публикуем ОДНУ комбинированную картинку (если DEBUG)
    if [ "$DEBUG" -eq 1 ]; then
      # Горизонтально: [code | value]; если высоты разные — IM сам подгонит подложкой
      convert "$SCRIPT_DIR/code.jpg" "$SCRIPT_DIR/value.jpg" +append "$SCRIPT_DIR/roi_combined.jpg" || cp "$SCRIPT_DIR/code.jpg" "$SCRIPT_DIR/roi_combined.jpg"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$IMG_TOPIC_COMBINED" -f "$SCRIPT_DIR/roi_combined.jpg" || log_error "MQTT ROI (combined) publish failed"
    fi

    # OCR значения (оставляю whitelist без '4', как ты и хотел)
    value=$(tesseract "$SCRIPT_DIR/value.jpg" stdout -l ssd_int --tessdata-dir "$SCRIPT_DIR" --psm 7 -c tessedit_char_whitelist=012356789)
    [ $? -ne 0 ] && { log_error "Ошибка OCR VALUE"; sleep "$SLEEP_INTERVAL"; continue; }
    value=$(echo "$value" | xargs)
    value=$(echo "$value" | sed 's/^0*//'); [ -z "$value" ] && value="0"

    timestamp=$(date --iso-8601=seconds)
    payload=$(printf '{"code": "%s", "value": "%s", "timestamp": "%s"}' "$code" "$value" "$timestamp")

    if [ "$code" = "1.8.0" ]; then
      log_debug "MQTT 1.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_TOPIC_1" -m "$payload" || log_error "Публикация 1.8.0 провалилась"
      published=1
    else
      log_debug "MQTT 2.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_TOPIC_2" -m "$payload" || log_error "Публикация 2.8.0 провалилась"
      published=1
    fi
  fi

  # Маркер «132.8.0» — особенность счётчика
  if [ "$code" = "132.8.0" ]; then
    published=2
  fi

  # Паузы
  if [ $published -eq 0 ]; then
    sleep "$SLEEP_INTERVAL"
  elif [ $published -eq 2 ]; then
    log_debug "Ожидаем '$EXTRA_PAUSE' сек и идём дальше..."
    sleep "$EXTRA_PAUSE"
  fi
done
