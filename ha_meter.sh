#!/usr/bin/env bash
# v0.4.0-simple — максимально упрощённая и надёжная версия
# - Код: только строгий OCR (user-words, whitelist), два простых препроцесса, PSM 8→7
# - VALUE: читается из того же кадра; без голосований; мягкая эвристика выбора
# - Анти-скачок: по дневным лимитам; можно ослабить в config
# - Double confirm отключён по умолчанию (config.double_confirm=false)
# - Лог чистится на старте (если log_truncate_on_start=true)

set -euo pipefail

############################
# Логирование
############################
normalize_bool() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)  return 0 ;;
    0|false|no|off|"") return 1 ;;
    *) return 0 ;;
  esac
}
DEBUG=1
LOG_TO_FILE=false
LOG_FILE=""
log_write_file(){ if normalize_bool "$LOG_TO_FILE"; then [ -n "$LOG_FILE" ] && echo "$1" >> "$LOG_FILE"; fi; }
log_debug(){ local msg="[DEBUG] $*"; normalize_bool "$DEBUG" && echo "$msg"; log_write_file "$msg"; }
log_error(){ local msg="[ERROR] $*"; echo "$msg" >&2; log_write_file "$msg"; }

############################
# Опции / окружение
############################
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OPTS_FILE="/data/options.json"

# Значения по умолчанию
CAMERA_URL="http://127.0.0.1/snap.jpg"
CODE_CROP="64x23+576+361"
VALUE_CROP="138x30+670+353"
DX=0; DY=0; PADY_CODE=2; PADY_VALUE=3

MQTT_HOST="localhost"; MQTT_USER="mqtt"; MQTT_PASSWORD="mqtt"
MQTT_TOPIC_1="homeassistant/sensor/energy_meter/1_8_0/state"
MQTT_TOPIC_2="homeassistant/sensor/energy_meter/2_8_0/state"
MQTT_CONFIG_TOPIC_1="homeassistant/sensor/energy_meter_1_8_0/config"
MQTT_CONFIG_TOPIC_2="homeassistant/sensor/energy_meter_2_8_0/config"

SLEEP_INTERVAL=1; EXTRA_PAUSE=108

VALUE_DECIMALS=3
DAILY_MAX_KWH_1_8_0=200
DAILY_MAX_KWH_2_8_0=50
BURST_MULT=2.0
MIN_STEP_UNITS=1
MAX_GAP_DAYS_CAP=3

DOUBLE_CONFIRM=false
STABLE_HITS=2
STABLE_HITS_COLD=2
PENDING_TTL_SEC=30

CODE_BURST_TRIES=2
CODE_BURST_DELAY_S=0.15

TESS_LANG="ssd_int"
STATE_DIR="$SCRIPT_DIR/state"

LOG_TRUNCATE_ON_START=true

# Чтение /data/options.json
if [ -f "$OPTS_FILE" ] && command -v jq >/dev/null 2>&1; then
  DEBUG="$(jq -r '.debug // true' "$OPTS_FILE")"

  CAMERA_URL="$(jq -r '.camera_url // "http://127.0.0.1/snap.jpg"' "$OPTS_FILE")"

  CODE_CROP="$(jq -r '.code_crop // "64x23+576+361"' "$OPTS_FILE")"
  VALUE_CROP="$(jq -r '.value_crop // "138x30+670+353"' "$OPTS_FILE")"
  DX="$(jq -r '.dx // 0' "$OPTS_FILE")"
  DY="$(jq -r '.dy // 0' "$OPTS_FILE")"
  PADY_CODE="$(jq -r '.pady_code // 2' "$OPTS_FILE")"
  PADY_VALUE="$(jq -r '.pady_value // 3' "$OPTS_FILE")"

  MQTT_HOST="$(jq -r '.mqtt_host // "localhost"' "$OPTS_FILE")"
  MQTT_USER="$(jq -r '.mqtt_user // "mqtt"' "$OPTS_FILE")"
  MQTT_PASSWORD="$(jq -r '.mqtt_password // "mqtt"' "$OPTS_FILE")"
  MQTT_TOPIC_1="$(jq -r '.mqtt_topic_1_8_0 // "homeassistant/sensor/energy_meter/1_8_0/state"' "$OPTS_FILE")"
  MQTT_TOPIC_2="$(jq -r '.mqtt_topic_2_8_0 // "homeassistant/sensor/energy_meter/2_8_0/state"' "$OPTS_FILE")"
  MQTT_CONFIG_TOPIC_1="$(jq -r '.mqtt_discovery_topic_1 // "homeassistant/sensor/energy_meter_1_8_0/config"' "$OPTS_FILE")"
  MQTT_CONFIG_TOPIC_2="$(jq -r '.mqtt_discovery_topic_2 // "homeassistant/sensor/energy_meter_2_8_0/config"' "$OPTS_FILE")"

  SLEEP_INTERVAL="$(jq -r '.sleep_interval // 1' "$OPTS_FILE")"
  EXTRA_PAUSE="$(jq -r '.extra_pause_after_2_8_0 // 108' "$OPTS_FILE")"

  VALUE_DECIMALS="$(jq -r '.value_decimals // 3' "$OPTS_FILE")"
  DAILY_MAX_KWH_1_8_0="$(jq -r '.daily_max_kwh_1_8_0 // 200' "$OPTS_FILE")"
  DAILY_MAX_KWH_2_8_0="$(jq -r '.daily_max_kwh_2_8_0 // 50' "$OPTS_FILE")"
  BURST_MULT="$(jq -r '.burst_mult // 2.0' "$OPTS_FILE")"
  MIN_STEP_UNITS="$(jq -r '.min_step_units // 1' "$OPTS_FILE")"
  MAX_GAP_DAYS_CAP="$(jq -r '.max_gap_days_cap // 3' "$OPTS_FILE")"

  DOUBLE_CONFIRM="$(jq -r '.double_confirm // false' "$OPTS_FILE")"
  STABLE_HITS="$(jq -r '.stable_hits // 2' "$OPTS_FILE")"
  STABLE_HITS_COLD="$(jq -r '.stable_hits_cold // 2' "$OPTS_FILE")"
  PENDING_TTL_SEC="$(jq -r '.pending_ttl_sec // 30' "$OPTS_FILE")"

  CODE_BURST_TRIES="$(jq -r '.code_burst_tries // 2' "$OPTS_FILE")"
  CODE_BURST_DELAY_S="$(jq -r '.code_burst_delay_s // 0.15' "$OPTS_FILE")"

  TESS_LANG="$(jq -r '.tess_lang // "ssd_int"' "$OPTS_FILE")"
  STATE_DIR="$(jq -r '.state_dir // "/data/state"' "$OPTS_FILE")"

  LOG_TO_FILE="$(jq -r '.log_to_file // true' "$OPTS_FILE")"
  LOG_FILE="$(jq -r '.log_file // "/data/ha_meter.log"' "$OPTS_FILE")"
  LOG_TRUNCATE_ON_START="$(jq -r '.log_truncate_on_start // true' "$OPTS_FILE")"
fi

# Лог-файл
normalize_bool "$DEBUG" && DEBUG=1 || DEBUG=0
if normalize_bool "$LOG_TO_FILE"; then
  mkdir -p "$(dirname "$LOG_FILE")"
  if normalize_bool "$LOG_TRUNCATE_ON_START"; then : > "$LOG_FILE"; echo "[DEBUG] Лог очищен: $LOG_FILE" >> "$LOG_FILE"; else touch "$LOG_FILE"; fi
fi
mkdir -p "$STATE_DIR"

log_debug "Опции: CAMERA_URL=$CAMERA_URL, CODE_CROP=$CODE_CROP, VALUE_CROP=$VALUE_CROP, DX/DY=${DX}/${DY}, DEBUG=$DEBUG"

############################
# Хелперы
############################
parse_roi(){ local r="$1"; local W=${r%%x*}; local rest=${r#*x}; local H=${rest%%+*}; local t=${r#*+}; local X=${t%%+*}; local Y=${r##*+}; echo "$W $H $X $Y"; }
fmt_roi(){ echo "${1}x${2}+${3}+${4}"; }
shift_roi(){ read -r W H X Y < <(parse_roi "$1"); fmt_roi "$W" "$H" "$((X+DX))" "$((Y+DY))"; }
pad_roi_y(){ local roi="$1" pad="$2"; read -r W H X Y < <(parse_roi "$roi"); fmt_roi "$W" "$((H+2*pad))" "$X" "$((Y-pad))"; }
intval(){ echo "${1:-0}" | awk '{if($0=="") print 0; else print int($0+0)}'; }
digits(){ echo "$1" | tr -cd '0-9'; }

TIMEOUT_BIN="$(command -v timeout || true)"
with_timeout(){ local sec="$1"; shift; if [ -n "$TIMEOUT_BIN" ]; then $TIMEOUT_BIN "$sec" "$@"; else "$@"; fi }

load_state_pair(){
  local code="$1" f="$STATE_DIR/last_${code}.txt"
  if [ -s "$f" ]; then
    local line; line="$(cat "$f")"
    if echo "$line" | grep -q '|'; then echo "${line%%|*} ${line##*|}"; else echo "$line $(stat -c %Y "$f" 2>/dev/null || date +%s)"; fi
  else
    echo ""
  fi
}
save_state_pair(){ local code="$1" v="$2" ts="$3"; echo -n "${v}|${ts}" > "$STATE_DIR/last_${code}.txt"; }
load_pending(){ local code="$1" f="$STATE_DIR/pending_${code}.txt"; [ -s "$f" ] && cat "$f" || echo ""; }
save_pending(){ local code="$1" val="$2" ts="${3:-$(date +%s)}" hits="${4:-1}"; echo "${val}|${ts}|${hits}" > "$STATE_DIR/pending_${code}.txt"; }
clear_pending(){ local code="$1"; rm -f "$STATE_DIR/pending_${code}.txt" 2>/dev/null || true; }

############################
# Анти-скачок
############################
allowed_jump_units(){ # $1=code $2=dt_sec
  local code="$1" dt="${2:-1}"
  [ "$dt" -lt 1 ] && dt=1
  local dt_cap=$(( MAX_GAP_DAYS_CAP * 86400 ))
  [ "$dt" -gt "$dt_cap" ] && dt="$dt_cap"
  local kwh_day; if [ "$code" = "1.8.0" ]; then kwh_day="$DAILY_MAX_KWH_1_8_0"; else kwh_day="$DAILY_MAX_KWH_2_8_0"; fi
  awk -v dt="$dt" -v kwh="$kwh_day" -v burst="$BURST_MULT" -v dec="$VALUE_DECIMALS" -v min="$MIN_STEP_UNITS" 'BEGIN{
    s=1; for(i=0;i<dec;i++) s*=10;
    v=kwh*(dt/86400.0)*s*burst; if(v<min) v=min;
    printf("%.0f\n", v);
  }'
}

############################
# Препроцесс/ОCR
############################
pp_code_A(){ convert "$1" -auto-orient -colorspace Gray -resize 320% -contrast-stretch 1%x1% -gamma 1.00 -threshold 60% -type bilevel "$2"; }
pp_code_B(){ convert "$1" -auto-orient -colorspace Gray -resize 320% -adaptive-threshold 29x29+8% -type bilevel "$2" 2>/dev/null || cp "$1" "$2"; }

pp_val_A(){ convert "$1" -auto-orient -colorspace Gray -clahe 64x64+10+2 -sigmoidal-contrast 6x50% -resize 300% -adaptive-threshold 41x41+8% -type bilevel "$2" 2>/dev/null || cp "$1" "$2"; }
pp_val_B(){ convert "$1" -colorspace Gray -auto-level -contrast-stretch 0.5%x0.5% -gamma 1.10 -resize 300% -threshold 52% -type bilevel "$2"; }

ocr_txt(){ tesseract "$1" stdout -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" --psm "$2" --oem 1 -c tessedit_char_whitelist="$3" -c classify_bln_numeric_mode=1 2>/dev/null | tr -d '\r'; }
ocr_code_strict(){
  local img="$1" uw out
  uw="$(mktemp --suffix=.words)"; printf "1.8.0\n2.8.0\n" > "$uw"
  out="$(tesseract "$img" stdout -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" --psm 8 --oem 1 \
        --user-words "$uw" -c load_system_dawg=F -c load_freq_dawg=F -c tessedit_char_whitelist=0128. 2>/dev/null | tr -d '\r' | xargs || true)"
  rm -f "$uw"
  case "$out" in "1.8.0"|"2.8.0") echo "$out" ;; *) echo "" ;; esac
}

read_code_simple(){ # $1=code.jpg -> echo "1.8.0|2.8.0|"
  local in="$1" a b s
  a="$(mktemp --suffix=.png)"; b="$(mktemp --suffix=.png)"
  pp_code_A "$in" "$a"
  s="$(ocr_code_strict "$a")"
  if [ -z "$s" ]; then
    pp_code_B "$in" "$b"
    s="$(ocr_code_strict "$b")"
  fi
  rm -f "$a" "$b"
  echo "$s"
}

read_value_simple(){ # $1=value.jpg $2=prev_int -> echo best
  local in="$1" prev="$2" a b vA vB best
  a="$(mktemp --suffix=.png)"; b="$(mktemp --suffix=.png)"
  pp_val_A "$in" "$a"; vA="$(digits "$(ocr_txt "$a" 7 '0123456789')")"
  pp_val_B "$in" "$b"; vB="$(digits "$(ocr_txt "$b" 7 '0123456789')")"
  rm -f "$a" "$b"
  if [ -n "$vA" ] && [ "$vA" = "$vB" ]; then echo "$vA"; return; fi
  if [ -n "$vA" ] && [ -z "$vB" ]; then echo "$vA"; return; fi
  if [ -z "$vA" ] && [ -n "$vB" ]; then echo "$vB"; return; fi
  # обе есть, разные — выберем ближний к prev
  local dA dB iA iB
  iA="$(intval "$vA")"; iB="$(intval "$vB")"
  dA=$(( iA>prev ? iA-prev : prev-iA ))
  dB=$(( iB>prev ? iB-prev : prev-iB ))
  if [ "$dA" -le "$dB" ]; then best="$vA"; else best="$vB"; fi
  echo "$best"
}

should_accept_value(){ # $1=code $2=new_s (digits) -> YES|NO:*
  local code="$1" new_s="$2"
  [ -z "$new_s" ] && { echo "NO:empty"; return; }
  local len=${#new_s}; if [ "$len" -lt 3 ] || [ "$len" -gt 9 ]; then echo "NO:len"; return; fi
  local cname; cname="$(echo "$code" | tr . _ )"
  local line last_s="" last_ts=0 now_ts
  line="$(load_state_pair "$cname")"
  if [ -n "$line" ]; then last_s="${line%% *}"; last_ts="${line##* }"; fi
  now_ts=$(date +%s)

  # cold start — при отключенном double_confirm публикуем сразу
  if [ -z "$last_s" ] && ! normalize_bool "$DOUBLE_CONFIRM"; then
    echo "YES:first"; return
  fi

  local last_i; last_i=$(intval "$last_s")
  local new_i;  new_i=$(intval "$new_s")

  if [ "$last_i" -gt 0 ] && [ "$new_i" -lt "$last_i" ]; then echo "NO:monotonic"; return; fi

  local dt=$(( now_ts - last_ts )); [ "$dt" -lt 1 ] && dt=1
  local allowed; allowed="$(allowed_jump_units "$code" "$dt")"
  local diff=$(( new_i - last_i ))
  if [ "$last_i" -gt 0 ] && [ "$diff" -gt "$allowed" ]; then echo "NO:jump($diff>$allowed)"; return; fi

  if normalize_bool "$DOUBLE_CONFIRM"; then
    local p pv rest pts phits age
    p="$(load_pending "$cname")"
    if [ -n "$p" ]; then
      pv="${p%%|*}"; rest="${p#*|}"; pts="${rest%%|*}"; phits="${rest#*|}"; [ "$phits" = "$pts" ] && phits=1
      age=$(( now_ts - pts ))
      if [ "$pv" = "$new_s" ] && [ "$age" -le "$PENDING_TTL_SEC" ]; then
        phits=$(( phits + 1 ))
        if [ "$phits" -ge "$STABLE_HITS" ]; then clear_pending "$cname"; echo "YES:confirmed"; return
        else save_pending "$cname" "$new_s" "$pts" "$phits"; echo "NO:pending"; return
        fi
      fi
    fi
    save_pending "$cname" "$new_s"; echo "NO:pending"; return
  fi

  echo "YES:ok"
}

publish_value(){
  local code="$1" value="$2" topic payload ts
  ts=$(date --iso-8601=seconds)
  payload=$(printf '{"code":"%s","value":"%s","timestamp":"%s"}' "$code" "$value" "$ts")
  if [ "$code" = "1.8.0" ]; then topic="$MQTT_TOPIC_1"; else topic="$MQTT_TOPIC_2"; fi
  log_debug "MQTT $code: $payload"
  with_timeout 5 mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$topic" -m "$payload" || log_error "mqtt publish failed"
  save_state_pair "$(echo "$code" | tr . _ )" "$value" "$(date +%s)"
}

############################
# MQTT discovery
############################
config_payload_1='{"name":"Energy Meter 1.8.0","state_topic":"'"$MQTT_TOPIC_1"'","unique_id":"energy_meter_1_8_0","unit_of_measurement":"kWh","value_template":"{{ value_json.value }}","json_attributes_topic":"'"$MQTT_TOPIC_1"'"}'
config_payload_2='{"name":"Energy Meter 2.8.0","state_topic":"'"$MQTT_TOPIC_2"'","unique_id":"energy_meter_2_8_0","unit_of_measurement":"kWh","value_template":"{{ value_json.value }}","json_attributes_topic":"'"$MQTT_TOPIC_2"'"}'
log_debug "Публикация конфигурации MQTT Discovery…"
with_timeout 5 mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_1" -m "$config_payload_1" || log_error "discovery 1.8.0"
with_timeout 5 mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_2" -m "$config_payload_2" || log_error "discovery 2.8.0"

############################
# Основной цикл
############################
while true; do
  published=0

  # burst попытки поймать кадр с кодом
  CODE_NORM=""
  for ((i=1; i<=CODE_BURST_TRIES; i++)); do
    log_debug "Скачивание скриншота… (try $i/$CODE_BURST_TRIES)"
    with_timeout 8 curl -fsSL --connect-timeout 5 --max-time 7 -o "$SCRIPT_DIR/full.jpg" "$CAMERA_URL" || true
    if [ ! -s "$SCRIPT_DIR/full.jpg" ]; then
      log_error "Не удалось получить full.jpg"; sleep "$SLEEP_INTERVAL"; continue
    fi

    CODE_ROI=$(pad_roi_y "$(shift_roi "$CODE_CROP")"  "$PADY_CODE")
    VALUE_ROI=$(pad_roi_y "$(shift_roi "$VALUE_CROP")" "$PADY_VALUE")

    convert "$SCRIPT_DIR/full.jpg" -crop "$CODE_ROI" +repage "$SCRIPT_DIR/code.jpg" || { log_error "КРОП code"; break; }
    CODE_NORM="$(read_code_simple "$SCRIPT_DIR/code.jpg")"
    log_debug "КОД='${CODE_NORM}' (try $i/$CODE_BURST_TRIES)"
    if [ -n "$CODE_NORM" ]; then break; fi
    sleep "$CODE_BURST_DELAY_S"
  done

  if [ -z "$CODE_NORM" ]; then
    log_debug "Код не распознан. Пропуск кадра."
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  # VALUE из того же кадра
  log_debug "Код принят ($CODE_NORM). Обрезка VALUE: $VALUE_ROI"
  convert "$SCRIPT_DIR/full.jpg" -crop "$VALUE_ROI" +repage "$SCRIPT_DIR/value.jpg" || { log_error "КРОП value"; sleep "$SLEEP_INTERVAL"; continue; }

  st_pair="$(load_state_pair "$(echo "$CODE_NORM" | tr . _ )")"
  prev_int=0; if [ -n "$st_pair" ]; then prev_int="$(intval "${st_pair%% *}")"; fi

  CAND="$(read_value_simple "$SCRIPT_DIR/value.jpg" "$prev_int")"
  CAND="${CAND##0}"; [ -z "$CAND" ] && CAND="0"
  verdict="$(should_accept_value "$CODE_NORM" "$CAND")"

  case "$verdict" in
    YES:*)       publish_value "$CODE_NORM" "$CAND"; published=1 ;;
    NO:pending)  log_debug "HOLD $CODE_NORM: ждём подтверждение ($CAND)" ;;
    NO:jump*)    log_debug "DROP $CODE_NORM: анти-скачок ($verdict)" ;;
    NO:monotonic)log_debug "DROP $CODE_NORM: нарушена монотонность" ;;
    NO:len)      log_debug "DROP $CODE_NORM: неподходящая длина" ;;
    NO:empty|NO:*)log_debug "DROP $CODE_NORM: пусто/мусор" ;;
  esac

  if [ $published -eq 0 ]; then
    sleep "$SLEEP_INTERVAL"
  elif [ "$CODE_NORM" = "2.8.0" ]; then
    sleep "$EXTRA_PAUSE"
  fi
done
