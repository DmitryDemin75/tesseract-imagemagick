#!/bin/bash
# ha_meter.sh — устойчивое чтение кодов 1.8.0 / 2.8.0 и значения (IM6 + Tesseract)

###############################################################################
# Отладка и логирование
###############################################################################
DEBUG=1
log_debug(){ [ "$DEBUG" -eq 1 ] && echo "[DEBUG] $*"; }
log_error(){ echo "[ERROR] $*" >&2; }

###############################################################################
# Твои актуальные настройки (сохранены)
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

# Интервалы (сек)
SLEEP_INTERVAL=1
EXTRA_PAUSE=108

# Базовые кропы (как у тебя)
CODE_CROP="64x23+576+361"     # зона кода 1.8.0 / 2.8.0
VALUE_CROP="138x30+670+353"   # зона значения

# МЯГКИЕ добавки
DX="${DX:-0}"                 # глобальный сдвиг X (+вправо / -влево)
DY="${DY:-0}"                 # глобальный сдвиг Y (+вниз / -вверх)
PADY_CODE="${PADY_CODE:-2}"   # «воздух» по Y для кода
PADY_VALUE="${PADY_VALUE:-3}" # «воздух» по Y для значения

# OCR
TESS_LANG="${TESS_LANG:-ssd_int}"   # ssd_int.traineddata рядом со скриптом
# CONF_MIN не используем жёстко (tesseract не даёт conf); оставляю на будущее
CONF_MIN="${CONF_MIN:-70}"

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

log_debug "Публикация конфигурации MQTT Discovery…"
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_1" -m "$config_payload_1" || log_error "discovery 1.8.0"
mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_2" -m "$config_payload_2" || log_error "discovery 2.8.0"

###############################################################################
# Утилиты для ROI и сравнения строк
###############################################################################
parse_roi(){ local r="$1"; local W=${r%%x*}; local rest=${r#*x}; local H=${rest%%+*}; local t=${r#*+}; local X=${t%%+*}; local Y=${r##*+}; echo "$W $H $X $Y"; }
fmt_roi(){ echo "${1}x${2}+${3}+${4}"; }
shift_roi(){ read -r W H X Y < <(parse_roi "$1"); fmt_roi "$W" "$H" "$((X+DX))" "$((Y+DY))"; }
pad_roi_y(){ local roi="$1" pad="$2"; read -r W H X Y < <(parse_roi "$roi"); fmt_roi "$W" "$((H+2*pad))" "$X" "$((Y-pad))"; }

# Левенштейн (awk). echo distance
lev(){
  awk -v s="$1" -v t="$2" '
  function min(a,b,c){m=a; if(b<m)m=b; if(c<m)m=c; return m}
  BEGIN{
    n=length(s); m=length(t);
    for(i=0;i<=n;i++) D[i,0]=i;
    for(j=0;j<=m;j++) D[0,j]=j;
    for(i=1;i<=n;i++){
      si=substr(s,i,1);
      for(j=1;j<=m;j++){
        tj=substr(t,j,1);
        cost=(si==tj)?0:1;
        a=D[i-1,j]+1; b=D[i,j-1]+1; c=D[i-1,j-1]+cost;
        D[i,j]=min(a,b,c);
      }
    }
    print D[n,m];
  }'
}

###############################################################################
# Препроцессоры ImageMagick (IM6)
###############################################################################
# КОД — маленькое окно: апскейл → контраст → фикс-порог; несколько вариантов
pp_code_A(){ convert "$1" -auto-orient -colorspace Gray -resize 350% -sigmoidal-contrast 6x50% -contrast-stretch 0.5%x0.5% -gamma 1.10 -blur 0x0.3 -threshold 58% -type bilevel "$2"; }
pp_code_B(){ convert "$1" -auto-orient -colorspace Gray -resize 350% -contrast-stretch 1%x1% -gamma 1.00 -threshold 60% -type bilevel "$2"; }
pp_code_C(){ convert "$1" -auto-orient -colorspace Gray -resize 350% -clahe 40x40+10+2 -sigmoidal-contrast 5x50% -threshold 56% -type bilevel "$2" 2>/dev/null || cp "$1" "$2"; }

# ЗНАЧЕНИЕ — адаптив + морфология; fallback — простой threshold
pp_value_main(){ convert "$1" -auto-orient -colorspace Gray -clahe 64x64+10+2 -sigmoidal-contrast 6x50% -deskew 40% -resize 300% -adaptive-threshold 41x41+8% -type bilevel -morphology Close Diamond:1 "$2" 2>/dev/null || return 1; }
pp_value_fb(){   convert "$1" -colorspace Gray -auto-level -contrast-stretch 0.5%x0.5% -gamma 1.10 -resize 300% -threshold 52% -type bilevel "$2"; }

###############################################################################
# OCR-обвязки
###############################################################################
ocr_text(){
  # $1=img $2=psm $3=whitelist
  tesseract "$1" stdout \
    -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" \
    --psm "$2" --oem 1 \
    -c tessedit_char_whitelist="$3" \
    -c classify_bln_numeric_mode=1 2>/dev/null | tr -d '\r'
}

clean_code(){  echo "$1" | tr -cd '0128.\n' | xargs; }   # ДЛЯ КОДА: только 0/1/2/8 и точка!
clean_value(){ echo "$1" | tr -cd '0-9\n'   | xargs; }

# Нормализация кода к 1.8.0 / 2.8.0 по Левенштейну (лучший из двух)
normalize_code_smart(){
  local raw="$1"
  local s="$(clean_code "$raw")"
  # Кандидаты
  local c1="1.8.0"; local c2="2.8.0"
  # Очистка множественных точек
  s="$(echo "$s" | sed 's/\.\././g')"
  # Считаем дистанции
  local d1="$(lev "$s" "$c1")"
  local d2="$(lev "$s" "$c2")"
  # Если обе дистанции большие — вернём пусто (считаем «неуверенным»)
  local thr=2
  if [ "$d1" -le "$thr" ] || [ "$d2" -le "$thr" ]; then
    if [ "$d1" -le "$d2" ]; then echo "$c1"; else echo "$c2"; fi
  else
    echo ""
  fi
}

# Мульти-распознавание кода (3 препро-пайплайна) → лучший результат по дистанции
read_code_best(){
  local in="$1"
  local best=""; local best_d=99
  local tmpA="$(mktemp --suffix=.png)"; local tmpB="$(mktemp --suffix=.png)"; local tmpC="$(mktemp --suffix=.png)"

  pp_code_A "$in" "$tmpA"
  pp_code_B "$in" "$tmpB"
  pp_code_C "$in" "$tmpC"

  for img in "$tmpA" "$tmpB" "$tmpC"; do
    local raw="$(ocr_text "$img" 8 '0128.')"
    local nor="$(normalize_code_smart "$raw")"
    if [ -n "$nor" ]; then
      local d1="$(lev "$(clean_code "$raw")" "1.8.0")"
      local d2="$(lev "$(clean_code "$raw")" "2.8.0")"
      local d=$(( d1 < d2 ? d1 : d2 ))
      if [ "$d" -lt "$best_d" ]; then best="$nor"; best_d="$d"; fi
    fi
  done

  rm -f "$tmpA" "$tmpB" "$tmpC"
  echo "$best"
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

  # Готовим ROI с учётом DX/DY и «воздуха»
  CODE_ROI=$(pad_roi_y "$(shift_roi "$CODE_CROP")"  "$PADY_CODE")
  VALUE_ROI=$(pad_roi_y "$(shift_roi "$VALUE_CROP")" "$PADY_VALUE")

  # --- КОД ---
  log_debug "Обрезка CODE: $CODE_ROI"
  convert "$SCRIPT_DIR/full.jpg" -crop "$CODE_ROI" +repage "$SCRIPT_DIR/code.jpg" || { log_error "КРОП code"; sleep $SLEEP_INTERVAL; continue; }

  CODE_TXT="$(read_code_best "$SCRIPT_DIR/code.jpg")"
  log_debug "КОД(best)='${CODE_TXT}'"

  published=0

  if [ "$CODE_TXT" = "1.8.0" ] || [ "$CODE_TXT" = "2.8.0" ]; then
    # --- ЗНАЧЕНИЕ ---
    log_debug "Код интересен ($CODE_TXT). Обрезка VALUE: $VALUE_ROI"
    convert "$SCRIPT_DIR/full.jpg" -crop "$VALUE_ROI" +repage "$SCRIPT_DIR/value.jpg" || { log_error "КРОП value"; sleep $SLEEP_INTERVAL; continue; }

    tmpV="$(mktemp --suffix=.png)"
    if ! pp_value_main "$SCRIPT_DIR/value.jpg" "$tmpV"; then
      pp_value_fb "$SCRIPT_DIR/value.jpg" "$tmpV"
    fi
    VALUE_RAW="$(ocr_text "$tmpV" 7 '0123456789')"
    rm -f "$tmpV"

    VALUE_TXT="$(clean_value "$VALUE_RAW")"
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
    log_debug "Код не распознан надёжно (получено '${CODE_TXT}'). Пропускаю кадр."
  fi

  # Паузы
  if [ $published -eq 0 ]; then
    sleep $SLEEP_INTERVAL
  elif [ $published -eq 2 ]; then
    sleep $EXTRA_PAUSE
  fi
done
