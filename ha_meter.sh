#!/bin/bash
# ha_meter.sh — устойчивое чтение кодов 1.8.0 / 2.8.0 и значения со счётчика (IM6 + Tesseract)

###############################################################################
# Отладка и логирование
###############################################################################
DEBUG=1
log_debug(){ [ "$DEBUG" -eq 1 ] && echo "[DEBUG] $*"; }
log_error(){ echo "[ERROR] $*" >&2; }

###############################################################################
# Твои текущие настройки (оставлены без изменений)
###############################################################################
SCRIPT_DIR=$(dirname "$0")

# Камера
CAMERA_URL="http://192.168.8.195/cgi-bin/CGIProxy.fcgi?cmd=snapPicture2&usr=admin&pwd=t1010113"

# MQTT
MQTT_HOST="192.168.8.20"
MQTT_USER="mqtt"
MQTT_PASSWORD="mqtt"

MQTT_TOPIC_1="homeassistant/sensor/energy_meter/1_8_0/state"
MQTT_TOPIC_2="homeassistant/sensor/energy_meter/2_8_0/state"

MQTT_CONFIG_TOPIC_1="homeassistant/sensor/energy_meter_1_8_0/config"
MQTT_CONFIG_TOPIC_2="homeassistant/sensor/energy_meter_2_8_0/config"

# Интервалы
SLEEP_INTERVAL=1
EXTRA_PAUSE=108

# Базовые кропы (как у тебя)
CODE_CROP="64x23+576+361"     # зона с кодом 1.8.0 / 2.8.0
VALUE_CROP="138x30+670+353"   # зона со значением

# МЯГКИЕ добавки (новые, но необязательные)
DX="${DX:-0}"                 # глобальный сдвиг X (+вправо / -влево)
DY="${DY:-0}"                 # глобальный сдвиг Y (+вниз / -вверх)
PADY_CODE="${PADY_CODE:-2}"   # «воздух» к высоте кода (px сверху и снизу)
PADY_VALUE="${PADY_VALUE:-3}" # «воздух» к высоте значения

# OCR
TESS_LANG="${TESS_LANG:-ssd_int}"   # ssd_int.traineddata рядом со скриптом
CONF_MIN="${CONF_MIN:-70}"          # порог уверенности (0..100), если получится вычислить

###############################################################################
# MQTT Discovery
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

log_debug "Публикация конфигурации MQTT Discovery…"
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
  -t "$MQTT_CONFIG_TOPIC_1" -m "$config_payload_1" || log_error "discovery 1.8.0"
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
  -t "$MQTT_CONFIG_TOPIC_2" -m "$config_payload_2" || log_error "discovery 2.8.0"

###############################################################################
# Вспомогательные функции
###############################################################################
parse_roi(){ # "WxH+X+Y" -> "W H X Y"
  local r="$1"; local W=${r%%x*}; local rest=${r#*x}; local H=${rest%%+*}
  local t=${r#*+}; local X=${t%%+*}; local Y=${r##*+}; echo "$W $H $X $Y"
}
fmt_roi(){ echo "${1}x${2}+${3}+${4}"; }
shift_roi(){ read -r W H X Y < <(parse_roi "$1"); fmt_roi "$W" "$H" "$((X+DX))" "$((Y+DY))"; }
pad_roi_y(){ local roi="$1" pad="$2"; read -r W H X Y < <(parse_roi "$roi"); fmt_roi "$W" "$((H+2*pad))" "$X" "$((Y-pad))"; }

# сравнение чисел устойчиво к пустым знач.
num_lt(){ awk -v a="$1" -v b="$2" 'BEGIN{ if(a=="") a=0; if(b=="") b=0; exit !(a+0 < b+0) }'; }

# Предобработка (IM6)
# 1) КОД — маленькое окно: апскейл → контраст → фикс-порог
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
# 2) ЗНАЧЕНИЕ — adaptive-threshold + морфология; fallback — простой threshold
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

# OCR текст
ocr_text(){
  local img="$1" psm="$2" wl="$3"
  tesseract "$img" stdout \
    -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" \
    --psm "$psm" --oem 1 \
    -c tessedit_char_whitelist="$wl" \
    -c classify_bln_numeric_mode=1 2>/dev/null | tr -d '\r'
}

# OCR уверенность: сначала TSV→если пусто, HOCR→если пусто, 0
ocr_conf_only(){
  local img="$1" psm="$2" wl="$3"

  # 1) TSV в stdout (если версия поддерживает)
  local tsv
  tsv="$(tesseract "$img" stdout \
          -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" \
          --psm "$psm" --oem 1 \
          -c tessedit_char_whitelist="$wl" \
          -c classify_bln_numeric_mode=1 \
          tsv 2>/dev/null)"
  if [ -n "$tsv" ]; then
    echo "$tsv" | awk -F'\t' 'NR>1 && $11!="" {s+=$11;n++} END{ if(n) printf("%.1f", s/n); else print "0"}'
    return
  fi

  # 2) HOCR (x_wconf)
  local hocr
  hocr="$(tesseract "$img" stdout \
           -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" \
           --psm "$psm" --oem 1 \
           -c tessedit_char_whitelist="$wl" \
           -c classify_bln_numeric_mode=1 \
           hocr 2>/dev/null)"
  if [ -n "$hocr" ]; then
    echo "$hocr" | grep -oE 'x_wconf [0-9]+' | awk '{s+=$2;n++} END{ if(n) printf("%.1f", s/n); else print "0"}'
    return
  fi

  # 3) Совсем старая версия — нет ни TSV, ни HOCR в stdout
  echo "0"
}

# Полный OCR: TEXT|CONF
ocr_text_conf(){
  local img="$1" psm="$2" wl="$3"
  local t c
  t="$(ocr_text "$img" "$psm" "$wl")"
  c="$(ocr_conf_only "$img" "$psm" "$wl")"
  [ -z "$c" ] && c=0
  echo "${t}|${c}"
}

clean_code(){  echo "$1" | tr -cd '0-9.\n' | xargs; }
clean_value(){ echo "$1" | tr -cd '0-9\n'   | xargs; }

normalize_code(){
  local s="$(echo "$1" | tr -cd '0-9.' )"
  s="${s## }"; s="${s%% }"
  s="$(echo "$s" | sed 's/\.\././g')"
  case "$s" in
    *"1.8.0"*|*"18.0"*|*"1.80"*|*"180"*) echo "1.8.0"; return ;;
    *"2.8.0"*|*"28.0"*|*"2.80"*|*"280"*) echo "2.8.0"; return ;;
  esac
  echo "$1"
}

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

  RAW_DPI=$(identify -format "%x" "$SCRIPT_DIR/full.jpg" 2>/dev/null || echo "")
  DPI=$(echo "$RAW_DPI" | sed 's/[^0-9.]//g'); [ -z "$DPI" ] && DPI=72
  log_debug "DPI: $DPI"

  CODE_ROI=$(pad_roi_y "$(shift_roi "$CODE_CROP")"  "$PADY_CODE")
  VALUE_ROI=$(pad_roi_y "$(shift_roi "$VALUE_CROP")" "$PADY_VALUE")

  # --- CODE ---
  log_debug "Обрезка CODE: $CODE_ROI"
  convert "$SCRIPT_DIR/full.jpg" -crop "$CODE_ROI" +repage "$SCRIPT_DIR/code.jpg" || {
    log_error "Ошибка обрезки области кода"; sleep $SLEEP_INTERVAL; continue; }

  pp_code "$SCRIPT_DIR/code.jpg" "$SCRIPT_DIR/code_pp.png"
  IFS='|' read -r CODE_RAW CODE_CONF <<<"$(ocr_text_conf "$SCRIPT_DIR/code_pp.png" 8 '0123456789.')"
  [ -z "$CODE_CONF" ] && CODE_CONF=0
  CODE_TXT="$(clean_code "$CODE_RAW")"
  CODE_TXT="$(normalize_code "$CODE_TXT")"
  log_debug "КОД='${CODE_TXT}' (conf=$CODE_CONF)"

  published=0

  if [ "$CODE_TXT" = "1.8.0" ] || [ "$CODE_TXT" = "2.8.0" ]; then
    # --- VALUE ---
    log_debug "Код интересен ($CODE_TXT). Обрезка VALUE: $VALUE_ROI"
    convert "$SCRIPT_DIR/full.jpg" -crop "$VALUE_ROI" +repage "$SCRIPT_DIR/value.jpg" || {
      log_error "Ошибка обрезки значения"; sleep $SLEEP_INTERVAL; continue; }

    pp_value "$SCRIPT_DIR/value.jpg" "$SCRIPT_DIR/value_pp.png"
    IFS='|' read -r VALUE_RAW VALUE_CONF <<<"$(ocr_text_conf "$SCRIPT_DIR/value_pp.png" 7 '0123456789')"
    [ -z "$VALUE_CONF" ] && VALUE_CONF=0
    VALUE_TXT="$(clean_value "$VALUE_RAW")"

    # Фоллбэк при пустом/коротком тексте ИЛИ низкой уверенности
    if [ -z "$VALUE_TXT" ] || [ "${#VALUE_TXT}" -lt 4 ] || num_lt "$VALUE_CONF" "$CONF_MIN"; then
      log_debug "VALUE fallback (txt='${VALUE_TXT}', conf=${VALUE_CONF})"
      convert "$SCRIPT_DIR/value.jpg" \
        -colorspace Gray -auto-level -contrast-stretch 0.5%x0.5% \
        -gamma 1.10 -resize 300% -blur 0x0.3 -threshold 52% -type bilevel \
        "$SCRIPT_DIR/value_fb.png"
      IFS='|' read -r VALUE_RAW2 VALUE_CONF2 <<<"$(ocr_text_conf "$SCRIPT_DIR/value_fb.png" 7 '0123456789')"
      [ -z "$VALUE_CONF2" ] && VALUE_CONF2=0
      if num_lt "$VALUE_CONF" "$VALUE_CONF2"; then
        VALUE_RAW="$VALUE_RAW2"; VALUE_CONF="$VALUE_CONF2"
      fi
      VALUE_TXT="$(clean_value "$VALUE_RAW")"
    fi

    VALUE_TXT="$(echo "$VALUE_TXT" | sed 's/^0*//')"
    [ -z "$VALUE_TXT" ] && VALUE_TXT="0"

    timestamp=$(date --iso-8601=seconds)
    payload=$(printf '{"code": "%s", "value": "%s", "timestamp": "%s"}' \
      "$CODE_TXT" "$VALUE_TXT" "$timestamp")

    if [ "$CODE_TXT" = "1.8.0" ]; then
      log_debug "MQTT 1.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "$MQTT_TOPIC_1" -m "$payload" || log_error "Ошибка публикации 1.8.0"
      published=1
    else
      log_debug "MQTT 2.8.0: $payload"
      mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "$MQTT_TOPIC_2" -m "$payload" || log_error "Ошибка публикации 2.8.0"
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
