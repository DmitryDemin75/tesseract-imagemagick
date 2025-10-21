#!/bin/bash
# ha_meter.sh

###############################################################################
# Отладка и логирование
###############################################################################
DEBUG=1
log_debug(){ [ "$DEBUG" -eq 1 ] && echo "[DEBUG] $*"; }
log_error(){ echo "[ERROR] $*" >&2; }

###############################################################################
# Основные настройки (как в твоей версии)
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
EXTRA_PAUSE=108

# Твои актуальные кропы
CODE_CROP="64x23+576+361"
VALUE_CROP="138x30+670+353"

# Добавил мягкие сдвиги и «воздух»
DX="${DX:-0}" ; DY="${DY:-0}"
PADY_CODE="${PADY_CODE:-2}"
PADY_VALUE="${PADY_VALUE:-3}"

# OCR
TESS_LANG="${TESS_LANG:-ssd_int}"
CONF_MIN="${CONF_MIN:-70}"

###############################################################################
# MQTT Discovery (как было)
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

log_debug "Публикую MQTT discovery…"
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_1" -m "$config_payload_1" || log_error "discovery 1.8.0"
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_2" -m "$config_payload_2" || log_error "discovery 2.8.0"

###############################################################################
# Вспомогательные функции
###############################################################################
parse_roi(){ local r="$1"; local W=${r%%x*}; local rest=${r#*x}; local H=${rest%%+*}; local t=${r#*+}; local X=${t%%+*}; local Y=${r##*+}; echo "$W $H $X $Y"; }
fmt_roi(){ echo "${1}x${2}+${3}+${4}"; }
shift_roi(){ read -r W H X Y < <(parse_roi "$1"); fmt_roi "$W" "$H" "$((X+DX))" "$((Y+DY))"; }
pad_roi_y(){ local roi="$1" pad="$2"; read -r W H X Y < <(parse_roi "$roi"); fmt_roi "$W" "$((H+2*pad))" "$X" "$((Y-pad))"; }

# Сравнение чисел без падений awk при пустых значениях
num_lt(){ awk -v a="$1" -v b="$2" 'BEGIN{ if(a=="") a=0; if(b=="") b=0; exit !(a+0 < b+0) }'; }

# Предобработка для КОДА: маленькое окно → сначала апскейл, потом контраст и порог (без -auto-threshold)
pp_code(){
  local in="$1" out="$2"
  convert "$in" \
    -auto-orient -colorspace Gray \
    -resize 350% \
    -sigmoidal-contrast 6x50% \
    -contrast-stretch 0.5%x0.5% \
    -gamma 1.10 \
    -blur 0x0.3 \
    -threshold 58% -type bilevel \
    "$out"
}

# Предобработка для ЗНАЧЕНИЯ: адаптивная бинаризация (ядро подобрано под ~138x30)
pp_value(){
  local in="$1" out="$2"
  convert "$in" \
    -auto-orient -colorspace Gray \
    -clahe 64x64+10+2 \
    -sigmoidal-contrast 6x50% \
    -deskew 40% \
    -resize 300% \
    -adaptive-threshold 41x41+8% -type bilevel \
    -morphology Close Diamond:1 \
    "$out" 2>/dev/null || \
  convert "$in" \
    -colorspace Gray -auto-level -contrast-stretch 0.5%x0.5% \
    -gamma 1.10 -resize 300% \
    -threshold 52% -type bilevel \
    "$out"
}

# OCR + средняя уверенность (пустую уверенность считаем 0)
ocr_conf(){
  local img="$1" psm="$2" wl="$3"
  local t c
  t=$(tesseract "$img" stdout --oem 1 --psm "$psm" -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" \
      -c tessedit_char_whitelist="$wl" -c classify_bln_numeric_mode=1 2>/dev/null | tr -d '\r')
  c=$(tesseract "$img" stdout tsv --oem 1 --psm "$psm" -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" \
      -c tessedit_char_whitelist="$wl" -c classify_bln_numeric_mode=1 2>/dev/null \
     | awk -F'\t' 'NR>1 && $10!="" {s+=$10;n++} END{ if(n) printf("%.1f",s/n); else print "0"}')
  echo "${t}|${c}"
}

clean_code(){  echo "$1" | tr -cd '0-9.\n' | xargs; }
clean_value(){ echo "$1" | tr -cd '0-9\n'   | xargs; }

# Нормализация кода: пытаемся свести к "1.8.0" или "2.8.0" из «кривых» вариантов
normalize_code(){
  local s="$(echo "$1" | tr -cd '0-9.' )"
  s="${s## }"; s="${s%% }"
  # убираем повторные точки
  s="$(echo "$s" | sed 's/\.\././g')"
  case "$s" in
    *"1.8.0"*|*"18.0"*|*"1.80"*|*"180"*) echo "1.8.0"; return ;;
    *"2.8.0"*|*"28.0"*|*"2.80"*|*"280"*) echo "2.8.0"; return ;;
  esac
  echo "$1"  # как есть
}

###############################################################################
# Основной цикл
###############################################################################
while true; do
  log_debug "Скачивание скриншота..."
  curl -s -o "$SCRIPT_DIR/full.jpg" "$CAMERA_URL"
  if [ $? -ne 0 ] || [ ! -f "$SCRIPT_DIR/full.jpg" ]; then
    log_error "Не удалось получить full.jpg"; sleep $SLEEP_INTERVAL; continue
  fi

  RAW_DPI=$(identify -format "%x" "$SCRIPT_DIR/full.jpg" 2>/dev/null || echo "")
  DPI=$(echo "$RAW_DPI" | sed 's/[^0-9.]//g'); [ -z "$DPI" ] && DPI=72
  log_debug "DPI: $DPI"

  CODE_ROI=$(pad_roi_y "$(shift_roi "$CODE_CROP")"  "$PADY_CODE")
  VALUE_ROI=$(pad_roi_y "$(shift_roi "$VALUE_CROP")" "$PADY_VALUE")

  # --- CODE ---
  log_debug "Обрезка CODE: $CODE_ROI"
  convert "$SCRIPT_DIR/full.jpg" -crop "$CODE_ROI" +repage "$SCRIPT_DIR/code.jpg" || { log_error "КРОП code"; sleep $SLEEP_INTERVAL; continue; }

  pp_code "$SCRIPT_DIR/code.jpg" "$SCRIPT_DIR/code_pp.png"
  IFS='|' read -r CODE_RAW CODE_CONF <<<"$(ocr_conf "$SCRIPT_DIR/code_pp.png" 8 '0123456789.')"
  [ -z "$CODE_CONF" ] && CODE_CONF=0
  CODE_TXT="$(clean_code "$CODE_RAW")"
  CODE_TXT="$(normalize_code "$CODE_TXT")"
  log_debug "КОД='${CODE_TXT}' (conf=$CODE_CONF)"

  published=0

  if [ "$CODE_TXT" = "1.8.0" ] || [ "$CODE_TXT" = "2.8.0" ]; then
    # --- VALUE ---
    log_debug "Код интересен ($CODE_TXT). Обрезка VALUE: $VALUE_ROI"
    convert "$SCRIPT_DIR/full.jpg" -crop "$VALUE_ROI" +repage "$SCRIPT_DIR/value.jpg" || { log_error "КРОП value"; sleep $SLEEP_INTERVAL; continue; }

    pp_value "$SCRIPT_DIR/value.jpg" "$SCRIPT_DIR/value_pp.png"
    IFS='|' read -r VALUE_RAW VALUE_CONF <<<"$(ocr_conf "$SCRIPT_DIR/value_pp.png" 7 '0123456789')"
    [ -z "$VALUE_CONF" ] && VALUE_CONF=0
    VALUE_TXT="$(clean_value "$VALUE_RAW")"

    # Если уверенность низкая — второй проход попроще (без adaptive)
    if num_lt "$VALUE_CONF" "$CONF_MIN"; then
      log_debug "VALUE conf=$VALUE_CONF < $CONF_MIN → fallback threshold"
      convert "$SCRIPT_DIR/value.jpg" \
        -colorspace Gray -auto-level -contrast-stretch 0.5%x0.5% \
        -gamma 1.10 -resize 300% -blur 0x0.3 -threshold 52% -type bilevel \
        "$SCRIPT_DIR/value_fb.png"
      IFS='|' read -r VALUE_RAW2 VALUE_CONF2 <<<"$(ocr_conf "$SCRIPT_DIR/value_fb.png" 7 '0123456789')"
      [ -z "$VALUE_CONF2" ] && VALUE_CONF2=0
      VALUE_RAW="$( [ "$(awk -v a="$VALUE_CONF2" -v b="$VALUE_CONF" 'BEGIN{print (a>b)?"1":"0"}')" = "1" ] && echo "$VALUE_RAW2" || echo "$VALUE_RAW" )"
      VALUE_CONF="$(awk -v a="$VALUE_CONF2" -v b="$VALUE_CONF" 'BEGIN{print (a>b)?a:b}')"
      VALUE_TXT="$(clean_value "$VALUE_RAW")"
    fi

    VALUE_TXT="$(echo "$VALUE_TXT" | sed 's/^0*//')"
    [ -z "$VALUE_TXT" ] && VALUE_TXT="0"
    timestamp=$(date --iso-8601=seconds)
    payload=$(printf '{"code": "%s", "value": "%s", "timestamp": "%s"}' "$CODE_TXT" "$VALUE_TXT" "$timestamp")

    if [ "$CODE_TXT" = "1.8.0" ]; then
      log_debug "MQTT 1.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_TOPIC_1" -m "$payload" || log_error "pub 1.8.0"
      published=1
    else
      log_debug "MQTT 2.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_TOPIC_2" -m "$payload" || log_error "pub 2.8.0"
      published=2
    fi
  else
    log_debug "Распознанный код '$CODE_TXT' не 1.8.0/2.8.0."
  fi

  # Паузы
  if [ $published -eq 0 ]; then
    sleep $SLEEP_INTERVAL
  elif [ $published -eq 2 ]; then
    sleep $EXTRA_PAUSE
  fi
done
