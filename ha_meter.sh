#!/bin/bash
# ha_meter.sh

###############################################################################
# Настройки отладки и функций логирования
###############################################################################
DEBUG=1  # Установите в 1 для включения отладочных сообщений

log_debug() { [ "$DEBUG" -eq 1 ] && echo "[DEBUG] $1"; }
log_error() { echo "[ERROR] $1" >&2; }

###############################################################################
# Основные настройки (как в твоей актуальной версии)
###############################################################################
SCRIPT_DIR=$(dirname "$0")

# URL для получения скриншота с камеры
CAMERA_URL="http://192.168.8.195/cgi-bin/CGIProxy.fcgi?cmd=snapPicture2&usr=admin&pwd=t1010113"

# MQTT-настройки
MQTT_HOST="192.168.8.20"
MQTT_USER="mqtt"
MQTT_PASSWORD="mqtt"

# Топики для публикации состояния
MQTT_TOPIC_1="homeassistant/sensor/energy_meter/1_8_0/state"
MQTT_TOPIC_2="homeassistant/sensor/energy_meter/2_8_0/state"

# Топики для конфигурации MQTT Discovery
MQTT_CONFIG_TOPIC_1="homeassistant/sensor/energy_meter_1_8_0/config"
MQTT_CONFIG_TOPIC_2="homeassistant/sensor/energy_meter_2_8_0/config"

# Интервалы (сек)
SLEEP_INTERVAL=1
EXTRA_PAUSE=108

# Координаты обрезки (твои актуальные)
CODE_CROP="64x23+576+361"     # Область с кодом (1.8.0 / 2.8.0)
VALUE_CROP="138x30+670+353"   # Область со значением (крупные цифры)

# --- Добавлено: мягкие глобальные сдвиги и «воздух» по высоте ---
DX="${DX:-0}"   # +вправо / -влево
DY="${DY:-0}"   # +вниз   / -вверх
PADY_CODE="${PADY_CODE:-2}"     # px сверху и снизу для кода
PADY_VALUE="${PADY_VALUE:-3}"   # px сверху и снизу для значения

# OCR-параметры
TESS_LANG="${TESS_LANG:-ssd_int}"   # файл ssd_int.traineddata лежит рядом со скриптом
CONF_MIN="${CONF_MIN:-70}"          # порог средней уверенности (0..100)

###############################################################################
# MQTT Discovery (как у тебя)
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
  -t "$MQTT_CONFIG_TOPIC_1" -m "$config_payload_1" || log_error "Ошибка публикации конфигурации 1.8.0"
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
  -t "$MQTT_CONFIG_TOPIC_2" -m "$config_payload_2" || log_error "Ошибка публикации конфигурации 2.8.0"

###############################################################################
# Вспомогательные функции (новые)
###############################################################################
parse_roi() { # "WxH+X+Y" -> echo "W H X Y"
  local r="$1"; local W=${r%%x*}; local rest=${r#*x}; local H=${rest%%+*}
  local tmp=${r#*+}; local X=${tmp%%+*}; local Y=${r##*+}; echo "$W $H $X $Y"
}
fmt_roi() { echo "${1}x${2}+${3}+${4}"; }
shift_roi() { read -r W H X Y < <(parse_roi "$1"); fmt_roi "$W" "$H" "$((X+DX))" "$((Y+DY))"; }
pad_roi_y() {
  local roi="$1" pad="$2"; read -r W H X Y < <(parse_roi "$roi")
  fmt_roi "$W" "$((H+2*pad))" "$X" "$((Y-pad))"
}

# Предобработка (IM6). Возвращает путь к PNG. Без -auto-threshold.
# ВАЖНО: ядра adaptive-threshold подобраны под маленькие кропы:
#  - для кода 64x(23..27) -> 25x25+10%
#  - для значения 138x(30..36) -> 41x41+8%
preprocess_png() {
  local jpg="$1" mode="$2" out; out="$(mktemp --suffix=.png)"
  local cla="64x64+10+2" ath="41x41+8%" morph=" -morphology Close Diamond:1 "
  local resize="300%"

  if [ "$mode" = "code" ]; then
    cla="40x40+10+2"
    ath="25x25+10%"
    morph=""
    resize="350%"   # чуть больше апскейл для маленького окна с кодом
  fi

  # Основной конвейер (CLAHE + deskew + adaptive-threshold)
  if convert "$jpg" \
      -auto-orient -colorspace Gray \
      -clahe $cla \
      -sigmoidal-contrast 6x50% \
      -deskew 40% \
      -resize $resize \
      -adaptive-threshold $ath -type bilevel \
      $morph \
      "$out" 2>/dev/null; then
    echo "$out"; return 0
  fi

  # Fallback для очень старых сборок: без clahe/deskew и без auto-threshold
  convert "$jpg" \
    -colorspace Gray -auto-level -contrast-stretch 0.5%x0.5% \
    -gamma 1.15 -resize $resize \
    -blur 0x0.3 \
    -threshold 55% -type bilevel \
    "$out"
  echo "$out"
}

# OCR + средняя уверенность (TSV). echo "TEXT|CONF"
ocr_with_conf() {
  local png="$1" mode="$2" psm wl
  if [ "$mode" = "code" ]; then psm=8; wl="0123456789."; else psm=7; wl="0123456789"; fi

  local txt conf
  txt=$(tesseract "$png" stdout --oem 1 --psm "$psm" \
        -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" \
        -c tessedit_char_whitelist="$wl" -c classify_bln_numeric_mode=1 2>/dev/null | tr -d '\r')
  conf=$(tesseract "$png" stdout tsv --oem 1 --psm "$psm" \
        -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" \
        -c tessedit_char_whitelist="$wl" -c classify_bln_numeric_mode=1 2>/dev/null \
        | awk -F'\t' 'NR>1&&$10!=""{s+=$10;n++}END{if(n)printf("%.1f",s/n);else print "0"}')
  echo "${txt}|${conf}"
}

clean_code()  { echo "$1" | tr -cd '0-9.\n' | xargs; }
clean_value() { echo "$1" | tr -cd '0-9\n'   | xargs; }

###############################################################################
# Основной цикл
###############################################################################
while true; do
  log_debug "Скачивание скриншота..."
  curl -s -o "$SCRIPT_DIR/full.jpg" "$CAMERA_URL"
  if [ $? -ne 0 ] || [ ! -f "$SCRIPT_DIR/full.jpg" ]; then
    log_error "Не удалось получить full.jpg"
    sleep $SLEEP_INTERVAL
    continue
  fi

  # DPI просто логируем (на JPEG это метаданные)
  RAW_DPI=$(identify -format "%x" "$SCRIPT_DIR/full.jpg" 2>/dev/null || echo "")
  DPI=$(echo "$RAW_DPI" | sed 's/[^0-9.]//g'); [ -z "$DPI" ] && DPI=72
  log_debug "DPI: $DPI"

  # Готовим ROI с учётом DX/DY и «воздуха»
  CODE_ROI=$(pad_roi_y "$(shift_roi "$CODE_CROP")"  "$PADY_CODE")
  VALUE_ROI=$(pad_roi_y "$(shift_roi "$VALUE_CROP")" "$PADY_VALUE")

  # --- CODE ---
  log_debug "Обрезка CODE: $CODE_ROI"
  convert "$SCRIPT_DIR/full.jpg" -crop "$CODE_ROI" +repage "$SCRIPT_DIR/code.jpg" || {
    log_error "Ошибка обрезки области с кодом"; sleep $SLEEP_INTERVAL; continue; }

  CODE_PP=$(preprocess_png "$SCRIPT_DIR/code.jpg" "code")
  IFS='|' read -r CODE_TXT CODE_CONF <<<"$(ocr_with_conf "$CODE_PP" "code")"
  CODE_TXT=$(clean_code "$CODE_TXT")
  log_debug "КОД='$CODE_TXT' (conf=$CODE_CONF)"

  # fallback OCR без -auto-threshold (если уверенность низкая)
  if awk "BEGIN{exit !($CODE_CONF < $CONF_MIN)}"; then
    log_debug "Низкая уверенность кода → упрощённый fallback"
    convert "$SCRIPT_DIR/code.jpg" \
      -colorspace Gray -auto-level -contrast-stretch 0.5%x0.5% \
      -gamma 1.15 -resize 350% -blur 0x0.3 -threshold 55% -type bilevel \
      "$SCRIPT_DIR/code_fallback.png"
    IFS='|' read -r CODE_TXT2 CODE_CONF2 <<<"$(ocr_with_conf "$SCRIPT_DIR/code_fallback.png" "code")"
    CODE_TXT2=$(clean_code "$CODE_TXT2")
    awk -v c1="$CODE_CONF" -v c2="$CODE_CONF2" 'BEGIN{exit !(c2>c1)}' && { CODE_TXT="$CODE_TXT2"; CODE_CONF="$CODE_CONF2"; }
  fi

  published=0

  if [ "$CODE_TXT" = "1.8.0" ] || [ "$CODE_TXT" = "2.8.0" ]; then
    # --- VALUE ---
    log_debug "Код интересен ($CODE_TXT). Обрезка VALUE: $VALUE_ROI"
    convert "$SCRIPT_DIR/full.jpg" -crop "$VALUE_ROI" +repage "$SCRIPT_DIR/value.jpg" || {
      log_error "Ошибка обрезки значения"; sleep $SLEEP_INTERVAL; continue; }

    VALUE_PP=$(preprocess_png "$SCRIPT_DIR/value.jpg" "value")
    IFS='|' read -r VALUE_TXT VALUE_CONF <<<"$(ocr_with_conf "$VALUE_PP" "value")"
    VALUE_TXT=$(clean_value "$VALUE_TXT")

    if awk "BEGIN{exit !($VALUE_CONF < $CONF_MIN)}"; then
      log_debug "Низкая уверенность значения → упрощённый fallback"
      convert "$SCRIPT_DIR/value.jpg" \
        -colorspace Gray -auto-level -contrast-stretch 0.5%x0.5% \
        -gamma 1.1 -resize 300% -blur 0x0.3 -threshold 50% -type bilevel \
        "$SCRIPT_DIR/value_fallback.png"
      IFS='|' read -r VALUE_TXT2 VALUE_CONF2 <<<"$(ocr_with_conf "$SCRIPT_DIR/value_fallback.png" "value")"
      VALUE_TXT2=$(clean_value "$VALUE_TXT2")
      awk -v c1="$VALUE_CONF" -v c2="$VALUE_CONF2" 'BEGIN{exit !(c2>c1)}' && { VALUE_TXT="$VALUE_TXT2"; VALUE_CONF="$VALUE_CONF2"; }
    fi

    # удаляем ведущие нули; если пусто — 0
    VALUE_TXT=$(echo "$VALUE_TXT" | sed 's/^0*//'); [ -z "$VALUE_TXT" ] && VALUE_TXT="0"

    timestamp=$(date --iso-8601=seconds)
    payload=$(printf '{"code": "%s", "value": "%s", "timestamp": "%s"}' \
      "$CODE_TXT" "$VALUE_TXT" "$timestamp")

    if [ "$CODE_TXT" = "1.8.0" ]; then
      log_debug "Публикация MQTT 1.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "$MQTT_TOPIC_1" -m "$payload" || log_error "Ошибка публикации 1.8.0"
      published=1
    else
      log_debug "Публикация MQTT 2.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "$MQTT_TOPIC_2" -m "$payload" || log_error "Ошибка публикации 2.8.0"
      published=2
    fi
  else
    log_debug "Распознанный код '$CODE_TXT' не соответствует интересующим (1.8.0 или 2.8.0)."
  fi

  # Задержки
  if [ $published -eq 0 ]; then
    sleep $SLEEP_INTERVAL
  elif [ $published -eq 2 ]; then
    sleep $EXTRA_PAUSE
  fi
done
