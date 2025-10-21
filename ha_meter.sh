#!/bin/bash
# ha_meter.sh — устойчивое чтение OBIS 1.8.0 / 2.8.0 и значения (IM6 + Tesseract)

###############################################################################
# Отладка и логирование
###############################################################################
DEBUG=1
log_debug(){ [ "$DEBUG" -eq 1 ] && echo "[DEBUG] $*"; }
log_error(){ echo "[ERROR] $*" >&2; }

###############################################################################
# Твои исходные настройки (оставлены)
###############################################################################
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

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

# Мягкие сдвиги и «воздух» по Y
DX="${DX:-0}" ; DY="${DY:-0}"
PADY_CODE="${PADY_CODE:-2}"     # даст фактическую высоту 27
PADY_VALUE="${PADY_VALUE:-3}"   # даст фактическую высоту 36

# OCR
TESS_LANG="${TESS_LANG:-ssd_int}"   # ssd_int.traineddata рядом со скриптом

###############################################################################
# Устойчивость и хранение состояния
###############################################################################
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/state}"
mkdir -p "$STATE_DIR"

# Масштаб показаний: сколько знаков после запятой «потеряно» в OCR (обычно 3)
VALUE_DECIMALS="${VALUE_DECIMALS:-3}"

# Суточные лимиты (кВт·ч/сутки)
DAILY_MAX_KWH_1_8_0="${DAILY_MAX_KWH_1_8_0:-200}"  # импорт
DAILY_MAX_KWH_2_8_0="${DAILY_MAX_KWH_2_8_0:-50}"   # экспорт

# Разрешённая «вспышка» нагрузки (множитель к среднему по ∆t)
BURST_MULT="${BURST_MULT:-2.0}"

# Минимальный шаг в «сырых» единицах
MIN_STEP_UNITS="${MIN_STEP_UNITS:-1}"

# Кэп на длительность простоя при расчёте допуска (сутки)
MAX_GAP_DAYS_CAP="${MAX_GAP_DAYS_CAP:-3}"

# Двойное подтверждение
STABLE_HITS="${STABLE_HITS:-2}"
PENDING_TTL_SEC="${PENDING_TTL_SEC:-60}"

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
# ROI/вспомогательные
###############################################################################
parse_roi(){ local r="$1"; local W=${r%%x*}; local rest=${r#*x}; local H=${rest%%+*}; local t=${r#*+}; local X=${t%%+*}; local Y=${r##*+}; echo "$W $H $X $Y"; }
fmt_roi(){ echo "${1}x${2}+${3}+${4}"; }
shift_roi(){ read -r W H X Y < <(parse_roi "$1"); fmt_roi "$W" "$H" "$((X+DX))" "$((Y+DY))"; }
pad_roi_y(){ local roi="$1" pad="$2"; read -r W H X Y < <(parse_roi "$roi"); fmt_roi "$W" "$((H+2*pad))" "$X" "$((Y-pad))"; }
intval(){ echo "$1" | awk '{if($0=="") print 0; else print int($0+0)}'; }

# Состояние last_{code}.txt: "value|ts"
load_state_pair(){ # $1=code with dots replaced -> echo "value ts"
  local code="$1" file="$STATE_DIR/last_${code}.txt"
  if [ -s "$file" ]; then
    local line; line="$(cat "$file")"
    if echo "$line" | grep -q '|'; then
      local v="${line%%|*}" ; local ts="${line##*|}"
      echo "$v $ts"
    else
      local v="$line" ; local ts="$(stat -c %Y "$file" 2>/dev/null || date +%s)"
      echo "$v $ts"
    fi
  else
    echo ""
  fi
}
save_state_pair(){ # $1=code with dots replaced, $2=value, $3=ts
  local code="$1" v="$2" ts="$3" file="$STATE_DIR/last_${code}.txt"
  echo -n "${v}|${ts}" > "$file"
}

# Pending-кандидат: "value|ts"
load_pending(){ local code="$1" file="$STATE_DIR/pending_${code}.txt"; [ -s "$file" ] && cat "$file" || echo ""; }
save_pending(){ local code="$1" val="$2" ts="$(date +%s)" file="$STATE_DIR/pending_${code}.txt"; echo "$val|$ts" > "$file"; }
clear_pending(){ local code="$1"; rm -f "$STATE_DIR/pending_${code}.txt" 2>/dev/null || true; }

# Инициализация state из MQTT retained (если локального state нет)
if command -v mosquitto_sub >/dev/null 2>&1; then
  if [ ! -s "$STATE_DIR/last_1_8_0.txt" ]; then
    v=$(mosquitto_sub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -C 1 -R -t "$MQTT_TOPIC_1" | awk -F'"' '/"value":/ {print $(NF-3)}' | tr -cd '0-9')
    [ -n "$v" ] && echo -n "${v}|$(date +%s)" > "$STATE_DIR/last_1_8_0.txt"
  fi
  if [ ! -s "$STATE_DIR/last_2_8_0.txt" ]; then
    v=$(mosquitto_sub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -C 1 -R -t "$MQTT_TOPIC_2" | awk -F'"' '/"value":/ {print $(NF-3)}' | tr -cd '0-9')
    [ -n "$v" ] && echo -n "${v}|$(date +%s)" > "$STATE_DIR/last_2_8_0.txt"
  fi
fi

###############################################################################
# Левенштейн (для нормализации кода)
###############################################################################
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
# Препроцесс (IM6) — код (3 ветки) и значение (3 ветки)
###############################################################################
pp_code_A(){ convert "$1" -auto-orient -colorspace Gray -resize 350% -sigmoidal-contrast 6x50% -contrast-stretch 0.5%x0.5% -gamma 1.10 -blur 0x0.3 -threshold 58% -type bilevel "$2"; }
pp_code_B(){ convert "$1" -auto-orient -colorspace Gray -resize 350% -contrast-stretch 1%x1% -gamma 1.00 -threshold 60% -type bilevel "$2"; }
pp_code_C(){ convert "$1" -auto-orient -colorspace Gray -resize 350% -clahe 40x40+10+2 -sigmoidal-contrast 5x50% -threshold 56% -type bilevel "$2" 2>/dev/null || cp "$1" "$2"; }

pp_val_A(){ convert "$1" -auto-orient -colorspace Gray -clahe 64x64+10+2 -sigmoidal-contrast 6x50% -deskew 40% -resize 300% -adaptive-threshold 41x41+8% -type bilevel -morphology Close Diamond:1 "$2" 2>/dev/null || cp "$1" "$2"; }
pp_val_B(){ convert "$1" -colorspace Gray -auto-level -contrast-stretch 0.5%x0.5% -gamma 1.10 -resize 300% -threshold 52% -type bilevel "$2"; }
pp_val_C(){ convert "$1" -colorspace Gray -auto-level -contrast-stretch 0.3%x0.3% -gamma 1.05 -resize 320% -threshold 58% -type bilevel "$2"; }

###############################################################################
# OCR-обвязки
###############################################################################
ocr_txt(){ # $1=img $2=psm $3=whitelist
  tesseract "$1" stdout -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" --psm "$2" --oem 1 \
    -c tessedit_char_whitelist="$3" -c classify_bln_numeric_mode=1 2>/dev/null | tr -d '\r'
}
clean_code(){  echo "$1" | tr -cd '0128.\n' | xargs; }  # только нужные символы
clean_value(){ echo "$1" | tr -cd '0-9\n'   | xargs; }

norm_code(){
  local raw="$1"; local s="$(clean_code "$raw")"; s="$(echo "$s" | sed 's/\.\././g')"
  local d1="$(lev "$s" "1.8.0")"; local d2="$(lev "$s" "2.8.0")"
  local thr=2
  if [ "$d1" -le "$thr" ] || [ "$d2" -le "$thr" ]; then
    [ "$d1" -le "$d2" ] && echo "1.8.0" || echo "2.8.0"
  else
    echo ""
  fi
}

read_code_best(){ # returns normalized (1.8.0/2.8.0) or ""
  local in="$1" tA tB tC nA nB nC
  local a="$(mktemp --suffix=.png)" b="$(mktemp --suffix=.png)" c="$(mktemp --suffix=.png)"
  pp_code_A "$in" "$a"; tA="$(ocr_txt "$a" 8 '0128.')" ; nA="$(norm_code "$tA")"
  pp_code_B "$in" "$b"; tB="$(ocr_txt "$b" 8 '0128.')" ; nB="$(norm_code "$tB")"
  pp_code_C "$in" "$c"; tC="$(ocr_txt "$c" 8 '0128.')" ; nC="$(norm_code "$tC")"
  rm -f "$a" "$b" "$c"
  local out=""
  for s in "$nA" "$nB" "$nC"; do [ -n "$s" ] && out="$s"; done
  if [ "$nA" = "$nB" ] && [ -n "$nA" ]; then out="$nA"; fi
  if [ "$nA" = "$nC" ] && [ -n "$nA" ]; then out="$nA"; fi
  if [ "$nB" = "$nC" ] && [ -n "$nB" ]; then out="$nB"; fi
  echo "$out"
}

digits(){ echo "$1" | tr -cd '0-9'; }
read_value_best(){ # $1=img $2=prev_value_int -> echo digits
  local in="$1" prev="$2"
  local a="$(mktemp --suffix=.png)" b="$(mktemp --suffix=.png)" c="$(mktemp --suffix=.png)"
  pp_val_A "$in" "$a"; local vA="$(digits "$(ocr_txt "$a" 7 '0123456789')")"
  pp_val_B "$in" "$b"; local vB="$(digits "$(ocr_txt "$b" 7 '0123456789')")"
  pp_val_C "$in" "$c"; local vC="$(digits "$(ocr_txt "$c" 7 '0123456789')")"
  rm -f "$a" "$b" "$c"
  local best=""
  for v in "$vA" "$vB" "$vC"; do [ -n "$v" ] && echo "$v"; done | sort | uniq -c | sort -nr | awk 'NR==1{print $2}' | read -r best || true
  if [ -z "$best" ] || [ "$best" = "0" ]; then
    local bestv=""; local bestd=999999999
    for v in "$vA" "$vB" "$vC"; do
      [ -z "$v" ] && continue
      local vi=$(intval "$v"); local d=$(( vi>prev ? vi-prev : prev-vi ))
      if [ "$d" -lt "$bestd" ]; then bestd="$d"; bestv="$v"; fi
    done
    best="$bestv"
  fi
  echo "$best"
}

###############################################################################
# Анти-скачок и публикация
###############################################################################
allowed_jump_units(){ # $1=code(1.8.0|2.8.0) $2=dt_sec
  local code="$1" dt="$2"
  [ "$dt" -lt 1 ] && dt=1
  local dt_cap=$(( MAX_GAP_DAYS_CAP * 86400 ))
  [ "$dt" -gt "$dt_cap" ] && dt="$dt_cap"
  local kwh_day
  if [ "$code" = "1.8.0" ]; then kwh_day="$DAILY_MAX_KWH_1_8_0"; else kwh_day="$DAILY_MAX_KWH_2_8_0"; fi
  local allowed
  allowed="$(awk -v dt="$dt" -v kwh="$kwh_day" -v burst="$BURST_MULT" -v dec="$VALUE_DECIMALS" '
    BEGIN{
      scale=1; for(i=0;i<dec;i++) scale*=10;
      val = kwh * (dt/86400.0) * scale * burst;
      if (val<1) val=1;
      printf("%.0f", val);
    }')"
  [ "$allowed" -lt "$MIN_STEP_UNITS" ] && echo "$MIN_STEP_UNITS" || echo "$allowed"
}

publish_value(){
  local code="$1" value="$2"
  local topic payload timestamp
  timestamp=$(date --iso-8601=seconds)
  payload=$(printf '{"code":"%s","value":"%s","timestamp":"%s"}' "$code" "$value" "$timestamp")
  if [ "$code" = "1.8.0" ]; then topic="$MQTT_TOPIC_1"; else topic="$MQTT_TOPIC_2"; fi
  log_debug "MQTT $code: $payload"
  mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$topic" -m "$payload" || log_error "pub $code"
  save_state_pair "$(echo "$code" | tr . _ )" "$value" "$(date +%s)"
}

should_accept(){
  # $1=code (1.8.0|2.8.0), $2=new_str_digits
  local code="$1" new_s="$2"
  [ -z "$new_s" ] && { echo "NO:empty"; return; }
  local len=${#new_s}; if [ "$len" -lt 3 ] || [ "$len" -gt 9 ]; then echo "NO:len"; return; fi

  local cname="$(echo "$code" | tr . _ )"
  local st; st="$(load_state_pair "$cname")"
  local last_s="" last_ts=0
  if [ -n "$st" ]; then last_s="${st%% *}"; last_ts="${st##* }"; else save_pending "$cname" "$new_s"; echo "NO:pending"; return; fi

  local last_i=$(intval "$last_s")
  local new_i=$(intval "$new_s")

  # монотонность
  if [ "$last_i" -gt 0 ] && [ "$new_i" -lt "$last_i" ]; then echo "NO:monotonic"; return; fi

  # динамический анти-скачок
  local now_ts=$(date +%s)
  local dt=$(( now_ts - last_ts )); [ "$dt" -lt 1 ] && dt=1
  local allowed=$(allowed_jump_units "$code" "$dt")
  local diff=$(( new_i - last_i ))
  if [ "$last_i" -gt 0 ] && [ "$diff" -gt "$allowed" ]; then echo "NO:jump($diff>$allowed)"; return; fi

  # двойное подтверждение
  local pend="$(load_pending "$cname")"
  if [ -n "$pend" ]; then
    local pv="${pend%%|*}" pts="${pend##*|}" age=$(( now_ts - pts ))
    if [ "$pv" = "$new_s" ] && [ "$age" -le "$PENDING_TTL_SEC" ]; then
      clear_pending "$cname"; echo "YES:confirmed"; return
    fi
  fi
  save_pending "$cname" "$new_s"
  echo "NO:pending"
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

  # --- КОД ---
  log_debug "Обрезка CODE: $CODE_ROI"
  convert "$SCRIPT_DIR/full.jpg" -crop "$CODE_ROI" +repage "$SCRIPT_DIR/code.jpg" || { log_error "КРОП code"; sleep $SLEEP_INTERVAL; continue; }
  CODE_NORM="$(read_code_best "$SCRIPT_DIR/code.jpg")"
  log_debug "КОД(best)='${CODE_NORM}'"

  published=0

  if [ "$CODE_NORM" = "1.8.0" ] || [ "$CODE_NORM" = "2.8.0" ]; then
    # --- ЗНАЧЕНИЕ ---
    log_debug "Код интересен ($CODE_NORM). Обрезка VALUE: $VALUE_ROI"
    convert "$SCRIPT_DIR/full.jpg" -crop "$VALUE_ROI" +repage "$SCRIPT_DIR/value.jpg" || { log_error "КРОП value"; sleep $SLEEP_INTERVAL; continue; }

    st_pair="$(load_state_pair "$(echo "$CODE_NORM" | tr . _ )")"
    prev_int=0; if [ -n "$st_pair" ]; then prev_int="$(intval "${st_pair%% *}")"; fi

    CAND="$(read_value_best "$SCRIPT_DIR/value.jpg" "$prev_int")"
    CAND="${CAND##0}" ; [ -z "$CAND" ] && CAND="0"  # убрать лидирующие нули

    verdict="$(should_accept "$CODE_NORM" "$CAND")"
    case "$verdict" in
      YES:*)
        publish_value "$CODE_NORM" "$CAND"; published=1 ;;
      NO:pending)
        log_debug "HOLD $CODE_NORM: ждём подтверждение ($CAND)" ;;
      NO:jump*)
        log_debug "DROP $CODE_NORM: анти-скачок ($verdict), last=$(load_state_pair "$(echo "$CODE_NORM" | tr . _ )") cand=$CAND" ;;
      NO:monotonic)
        log_debug "DROP $CODE_NORM: нарушена монотонность" ;;
      NO:len)
        log_debug "DROP $CODE_NORM: неподходящая длина" ;;
      NO:empty|NO:*)
        log_debug "DROP $CODE_NORM: пусто/мусор" ;;
    esac

    # задержки как у тебя
    if [ $published -eq 0 ]; then
      sleep $SLEEP_INTERVAL
    elif [ "$CODE_NORM" = "2.8.0" ]; then
      sleep $EXTRA_PAUSE
    fi
  else
    log_debug "Код не распознан надёжно. Пропускаю кадр."
    sleep $SLEEP_INTERVAL
  fi
done
