#!/bin/bash
# ha_meter.sh

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
# Основные настройки
###############################################################################
# Путь к директории скрипта (используется для .traineddata и временных файлов)
SCRIPT_DIR=$(dirname "$0")

# URL для получения скриншота с камеры
#CAMERA_URL="http://192.168.8.84:11080/endpoint/@scrypted/webhook/public/260/43f2d459c931e58b/takePicture"
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
SLEEP_INTERVAL=1   # Основной интервал между итерациями
EXTRA_PAUSE=108     # Дополнительная пауза после публикации кода 2.8.0

# Координаты обрезки (фиксированные для обоих кодов)
CODE_CROP="64x27+576+359"    # Область с кодом (1.8.0 / 2.8.0)
VALUE_CROP="138x30+670+353"   # Область со значением (крупные цифры)

CODE_CROP="64x23+576+361" 
VALUE_CROP="134x30+670+353"

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

mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
  -t "$MQTT_CONFIG_TOPIC_1" -m "$config_payload_1"
if [ $? -ne 0 ]; then
  log_error "Ошибка публикации конфигурационного сообщения для сенсора 1.8.0"
fi

mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
  -t "$MQTT_CONFIG_TOPIC_2" -m "$config_payload_2"
if [ $? -ne 0 ]; then
  log_error "Ошибка публикации конфигурационного сообщения для сенсора 2.8.0"
fi

###############################################################################
# Основной цикл
###############################################################################
while true; do
  #log_debug "Скачивание скриншота..."
  curl -s -o "$SCRIPT_DIR/full.jpg" "$CAMERA_URL"
  if [ $? -ne 0 ]; then
    log_error "Ошибка скачивания скриншота с камеры."
    sleep $SLEEP_INTERVAL
    continue
  fi

  if [ ! -f "$SCRIPT_DIR/full.jpg" ]; then
    log_error "Файл скриншота не найден."
    sleep $SLEEP_INTERVAL
    continue
  fi

  # --- Определение разрешения (DPI) скачанного скриншота ---
  RAW_DPI=$(identify -format "%x" "$SCRIPT_DIR/full.jpg")
  DPI=$(echo "$RAW_DPI" | sed 's/[^0-9.]//g')
  if [ -z "$DPI" ] || [ "$DPI" = "0" ]; then
    DPI=300
  fi
  #log_debug "Используем разрешение: ${DPI} dpi"

  #log_debug "Обрезка области с кодом..."
  # Добавляем параметры -density и -units PixelsPerInch для корректной обработки изображения
  convert -density "$DPI" -units PixelsPerInch "$SCRIPT_DIR/full.jpg" -crop $CODE_CROP +repage "$SCRIPT_DIR/code.jpg"
  #magick $SCRIPT_DIR/full.jpg -crop $CODE_CROP +repage "$SCRIPT_DIR/code.jpg"
  if [ $? -ne 0 ]; then
    log_error "Ошибка обрезки области с кодом."
    continue
  fi

  # Распознаём код (разрешены цифры и точка)
  code=$(tesseract "$SCRIPT_DIR/code.jpg" stdout \
    -l ssd_int --tessdata-dir "$SCRIPT_DIR" --psm 7 \
    -c tessedit_char_whitelist=0123456789.)
  if [ $? -ne 0 ]; then
    log_error "Ошибка OCR для кода."
    continue
  fi
  code=$(echo "$code" | xargs)
  log_debug "Распознан код: '$code'"

  if [ "$code" = "1.8.0" ] || [ "$code" = "18.0" ]; then
    code="1.8.0"
  fi

  published=0

  # Обрабатываем только коды 1.8.0 и 2.8.0
  if [ "$code" = "1.8.0" ] || [ "$code" = "2.8.0" ]; then
    log_debug "Код '$code' соответствует интересующему. Обрезка области со значением..."
    convert -density "$DPI" -units PixelsPerInch "$SCRIPT_DIR/full.jpg" -crop $VALUE_CROP +repage "$SCRIPT_DIR/value.jpg"
    #magick $SCRIPT_DIR/full.jpg -crop $VALUE_CROP +repage "$SCRIPT_DIR/code.jpg"
    if [ $? -ne 0 ]; then
      log_error "Ошибка обрезки области со значением."
      continue
    fi

    # Распознаём значение (разрешены цифры, точка и дефис)
    value=$(tesseract "$SCRIPT_DIR/value.jpg" stdout \
      -l ssd_int --tessdata-dir "$SCRIPT_DIR" --psm 7 \
      -c tessedit_char_whitelist=012356789)
    if [ $? -ne 0 ]; then
      log_error "Ошибка OCR для значения."
      continue
    fi
    value=$(echo "$value" | xargs)  # Убираем пробелы вокруг

    # Удаляем ведущие нули (преобразуем к int). Если строка пуста – ставим "0"
    value=$(echo "$value" | sed 's/^0*//')
    if [ -z "$value" ]; then
      value="0"
    fi

    timestamp=$(date --iso-8601=seconds)
    
    payload=$(printf '{"code": "%s", "value": "%s", "timestamp": "%s"}' \
      "$code" "$value" "$timestamp")

    # Публикация для кода 1.8.0
    if [ "$code" = "1.8.0" ]; then
      log_debug "Публикация MQTT для кода 1.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "$MQTT_TOPIC_1" -m "$payload"
      if [ $? -ne 0 ]; then
        log_error "Ошибка публикации данных для 1.8.0."
      fi
      published=1

    # Публикация для кода 2.8.0
    elif [ "$code" = "2.8.0" ]; then
      log_debug "Публикация MQTT для кода 2.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "$MQTT_TOPIC_2" -m "$payload"
      if [ $? -ne 0 ]; then
        log_error "Ошибка публикации данных для 2.8.0."
      fi
      published=2
    fi
  else
    #log_debug "Распознанный код '$code' не соответствует интересующим (1.8.0 или 2.8.0)."
  fi

  # Логика задержек
  if [ $published -eq 0 ]; then
    # Если публикация не производилась, ждём стандартное время
    sleep $SLEEP_INTERVAL
  elif [ $published -eq 2 ]; then
    # Если опубликован код 2.8.0, делаем дополнительную паузу
    sleep $EXTRA_PAUSE
  fi

done
