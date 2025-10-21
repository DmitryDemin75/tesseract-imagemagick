#!/usr/bin/env bash
# v0.4.5-relaxed-chop
# Новое:
# - VALUE_CHOP_RIGHT (и CODE_CHOP_RIGHT) — «срез» справа (по умолчанию 4 и 1 пиксель)
# - Два варианта OCR значения: normal vs chopped-right; хак на «хвостовую 1»
# - Выбор кандидата по близости к предыдущему, затем по отсутствию хвостовой «1»
# - Отладка строго в stderr

set -Eeo pipefail

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
log_debug(){ local msg="[DEBUG] $*"; normalize_bool "$DEBUG" && { echo "$msg" >&2; }; log_write_file "$msg"; }
log_error(){ local msg="[ERROR] $*"; echo "$msg" >&2; log_write_file "$msg"; }

############################
# Опции / окружение
############################
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OPTS_FILE="/data/options.json"

# Дефолты
CAMERA_URL="http://127.0.0.1/snap.jpg"

CODE_CROP="64x23+576+361"
VALUE_CROP="138x30+670+353"
DX=0; DY=0
PADY_CODE=4
PADY_VALUE=3

# НОВОЕ: «срезы» справа (в пикселях) для борьбы с ложной вертикалью = «1»
CODE_CHOP_RIGHT=1
VALUE_CHOP_RIGHT=4

MQTT_HOST="localhost"; MQTT_USER="mqtt"; MQTT_PASSWORD="mqtt"
MQTT_TOPIC_1="homeassistant/sensor/energy_meter/1_8_0/state"
MQTT_TOPIC_2="homeassistant/sensor/energy_meter/2_8_0/state"
MQTT_CONFIG_TOPIC_1="homeassistant/sensor/energy_meter_1_8_0/config"
MQTT_CONFIG_TOPIC_2="homeassistant/sensor/energy_meter_2_8_0/config"

SLEEP_INTERVAL=1
EXTRA_PAUSE=108

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

CODE_BURST_TRIES=3
CODE_BURST_DELAY_S=0.15

TESS_LANG="ssd_int"
STATE_DIR="$SCRIPT_DIR/state"

# Ограничения длины значения (anti-trash)
VAL_MIN_1_8_0=5
VAL_MAX_1_8_0=7
VAL_MIN_2_8_0=3
VAL_MAX_2_8_0=6

LOG_TO_FILE=true
LOG_FILE="/data/ha_meter.log"
LOG_TRUNCATE_ON_START=true

# Чтение /data/options.json (все ключи опциональны)
if [ -f "$OPTS_FILE" ] && command -v jq >/dev/null 2>&1; then
  DEBUG="$(jq -r '.debug // empty' "$OPTS_FILE")";                    : "${DEBUG:=true}"

  CAMERA_URL="$(jq -r '.camera_url // empty' "$OPTS_FILE")";         : "${CAMERA_URL:=http://127.0.0.1/snap.jpg}"

  CODE_CROP="$(jq -r '.code_crop // empty' "$OPTS_FILE")";           : "${CODE_CROP:=64x23+576+361}"
  VALUE_CROP="$(jq -r '.value_crop // empty' "$OPTS_FILE")";         : "${VALUE_CROP:=138x30+670+353}"
  DX="$(jq -r '.dx // empty' "$OPTS_FILE")";                         : "${DX:=0}"
  DY="$(jq -r '.dy // empty' "$OPTS_FILE")";                         : "${DY:=0}"
  PADY_CODE="$(jq -r '.pady_code // empty' "$OPTS_FILE")";           : "${PADY_CODE:=4}"
  PADY_VALUE="$(jq -r '.pady_value // empty' "$OPTS_FILE")";         : "${PADY_VALUE:=3}"

  CODE_CHOP_RIGHT="$(jq -r '.code_chop_right // empty' "$OPTS_FILE")";   : "${CODE_CHOP_RIGHT:=1}"
  VALUE_CHOP_RIGHT="$(jq -r '.value_chop_right // empty' "$OPTS_FILE")"; : "${VALUE_CHOP_RIGHT:=4}"

  MQTT_HOST="$(jq -r '.mqtt_host // empty' "$OPTS_FILE")";           : "${MQTT_HOST:=localhost}"
  MQTT_USER="$(jq -r '.mqtt_user // empty' "$OPTS_FILE")";           : "${MQTT_USER:=mqtt}"
  MQTT_PASSWORD="$(jq -r '.mqtt_password // empty' "$OPTS_FILE")";   : "${MQTT_PASSWORD:=mqtt}"
  MQTT_TOPIC_1="$(jq -r '.mqtt_topic_1_8_0 // empty' "$OPTS_FILE")"; : "${MQTT_TOPIC_1:=homeassistant/sensor/energy_meter/1_8_0/state}"
  MQTT_TOPIC_2="$(jq -r '.mqtt_topic_2_8_0 // empty' "$OPTS_FILE")"; : "${MQTT_TOPIC_2:=homeassistant/sensor/energy_meter/2_8_0/state}"
  MQTT_CONFIG_TOPIC_1="$(jq -r '.mqtt_discovery_topic_1 // empty' "$OPTS_FILE")"; : "${MQTT_CONFIG_TOPIC_1:=homeassistant/sensor/energy_meter_1_8_0/config}"
  MQTT_CONFIG_TOPIC_2="$(jq -r '.mqtt_discovery_topic_2 // empty' "$OPTS_FILE")"; : "${MQTT_CONFIG_TOPIC_2:=homeassistant/sensor/energy_meter_2_8_0/config}"

  SLEEP_INTERVAL="$(jq -r '.sleep_interval // empty' "$OPTS_FILE")"; : "${SLEEP_INTERVAL:=1}"
  EXTRA_PAUSE="$(jq -r '.extra_pause_after_2_8_0 // empty' "$OPTS_FILE")"; : "${EXTRA_PAUSE:=108}"

  VALUE_DECIMALS="$(jq -r '.value_decimals // empty' "$OPTS_FILE")"; : "${VALUE_DECIMALS:=3}"
  DAILY_MAX_KWH_1_8_0="$(jq -r '.daily_max_kwh_1_8_0 // empty' "$OPTS_FILE")"; : "${DAILY_MAX_KWH_1_8_0:=200}"
  DAILY_MAX_KWH_2_8_0="$(jq -r '.daily_max_kwh_2_8_0 // empty' "$OPTS_FILE")"; : "${DAILY_MAX_KWH_2_8_0:=50}"
  BURST_MULT="$(jq -r '.burst_mult // empty' "$OPTS_FILE")";         : "${BURST_MULT:=2.0}"
  MIN_STEP_UNITS="$(jq -r '.min_step_units // empty' "$OPTS_FILE")"; : "${MIN_STEP_UNITS:=1}"
  MAX_GAP_DAYS_CAP="$(jq -r '.max_gap_days_cap // empty' "$OPTS_FILE")"; : "${MAX_GAP_DAYS_CAP:=3}"

  DOUBLE_CONFIRM="$(jq -r '.double_confirm // empty' "$OPTS_FILE")"; : "${DOUBLE_CONFIRM:=false}"
  STABLE_HITS="$(jq -r '.stable_hits // empty' "$OPTS_FILE")";       : "${STABLE_HITS:=2}"
  STABLE_HITS_COLD="$(jq -r '.stable_hits_cold // empty' "$OPTS_FILE")"; : "${STABLE_HITS_COLD:=2}"
  PENDING_TTL_SEC="$(jq -r '.pending_ttl_sec // empty' "$OPTS_FILE")"; : "${PENDING_TTL_SEC:=30}"

  CODE_BURST_TRIES="$(jq -r '.code_burst_tries // empty' "$OPTS_FILE")"; : "${CODE_BURST_TRIES:=3}"
  CODE_BURST_DELAY_S="$(jq -r '.code_burst_delay_s // empty' "$OPTS_FILE")"; : "${CODE_BURST_DELAY_S:=0.15}"

  TESS_LANG="$(jq -r '.tess_lang // empty' "$OPTS_FILE")";           : "${TESS_LANG:=ssd_int}"
  STATE_DIR="$(jq -r '.state_dir // empty' "$OPTS_FILE")";           : "${STATE_DIR:=$SCRIPT_DIR/state}"

  LOG_TO_FILE="$(jq -r '.log_to_file // empty' "$OPTS_FILE")";       : "${LOG_TO_FILE:=true}"
  LOG_FILE="$(jq -r '.log_file // empty' "$OPTS_FILE")";             : "${LOG_FILE:=/data/ha_meter.log}"
  LOG_TRUNCATE_ON_START="$(jq -r '.log_truncate_on_start // empty' "$OPTS_FILE")"; : "${LOG_TRUNCATE_ON_START:=true}"

  VAL_MIN_1_8_0="$(jq -r '.val_min_1_8_0 // empty' "$OPTS_FILE")";   : "${VAL_MIN_1_8_0:=5}"
  VAL_MAX_1_8_0="$(jq -r '.val_max_1_8_0 // empty' "$OPTS_FILE")";   : "${VAL_MAX_1_8_0:=7}"
  VAL_MIN_2_8_0="$(jq -r '.val_min_2_8_0 // empty' "$OPTS_FILE")";   : "${VAL_MIN_2_8_0:=3}"
  VAL_MAX_2_8_0="$(jq -r '.val_max_2_8_0 // empty' "$OPTS_FILE")";   : "${VAL_MAX_2_8_0:=6}"
fi

# Лог-файл
normalize_bool "$DEBUG" && DEBUG=1 || DEBUG=0
if normalize_bool "$LOG_TO_FILE"; then
  mkdir -p "$(dirname "$LOG_FILE")"
  if normalize_bool "$LOG_TRUNCATE_ON_START"; then : > "$LOG_FILE"; echo "[DEBUG] Лог очищен: $LOG_FILE" >> "$LOG_FILE"; else touch "$LOG_FILE"; fi
fi
mkdir -p "$STATE_DIR"

log_debug "Опции: CAMERA_URL=$CAMERA_URL, CODE_CROP=$CODE_CROP, VALUE_CROP=$VALUE_CROP, DX/DY=${DX}/${DY}, DEBUG=$DEBUG, CHOP_R(code/val)=${CODE_CHOP_RIGHT}/${VALUE_CHOP_RIGHT}"

############################
# Хелперы
############################
parse_roi(){ local r="${1:-0x0+0+0}"; local W=${r%%x*}; local rest=${r#*x}; local H=${rest%%+*}; local t=${r#*+}; local X=${t%%+*}; local Y=${r##*+}; echo "$W $H $X $Y"; }
fmt_roi(){ echo "${1}x${2}+${3}+${4}"; }
shift_roi(){ read -r W H X Y < <(parse_roi "${1:-0x0+0+0}"); fmt_roi "$W" "$H" "$((X+DX))" "$((Y+DY))"; }
pad_roi_y(){ local roi="${1:-0x0+0+0}" pad="${2:-0}"; read -r W H X Y < <(parse_roi "$roi"); fmt_roi "$W" "$((H+2*pad))" "$X" "$((Y-pad))"; }
intval(){ echo "${1:-0}" | awk '{if($0=="") print 0; else print int($0+0)}'; }
digits(){ echo "${1:-}" | tr -cd '0-9'; }
lstrip_zeros(){ local s="${1:-}"; s="$(echo -n "$s" | sed 's/^0\+//')"; [ -z "$s" ] && echo 0 || echo "$s"; }

TIMEOUT_BIN="$(command -v timeout || true)"
with_timeout(){ local sec="${1:-}"; shift || true; if [ -n "$TIMEOUT_BIN" ]; then $TIMEOUT_BIN "$sec" "$@"; else "$@"; fi }

load_state_pair(){
  local _code="${1:-}" f="$STATE_DIR/last_${_code}.txt"
  if [ -n "$_code" ] && [ -s "$f" ]; then
    local line; line="$(cat "$f")"
    if echo "$line" | grep -q '|'; then echo "${line%%|*} ${line##*|}"; else echo "$line $(stat -c %Y "$f" 2>/dev/null || date +%s)"; fi
  else
    echo ""
  fi
}
save_state_pair(){ local _code="${1:-}" v="${2:-}" ts="${3:-}"; [ -n "$_code" ] && echo -n "${v}|${ts}" > "$STATE_DIR/last_${_code}.txt"; }

############################
# Анти-скачок
############################
allowed_jump_units(){ # $1=code $2=dt_sec
  local _code="${1:-1.8.0}" _dt="${2:-1}"
  [ "${_dt:-0}" -lt 1 ] && _dt=1
  local dt_cap=$(( MAX_GAP_DAYS_CAP * 86400 ))
  [ "${_dt:-0}" -gt "$dt_cap" ] && _dt="$dt_cap"
  local kwh_day; if [ "$_code" = "1.8.0" ]; then kwh_day="$DAILY_MAX_KWH_1_8_0"; else kwh_day="$DAILY_MAX_KWH_2_8_0"; fi
  awk -v dt="$_dt" -v kwh="$kwh_day" -v burst="$BURST_MULT" -v dec="$VALUE_DECIMALS" -v min="$MIN_STEP_UNITS" 'BEGIN{
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

ocr_txt(){ tesseract "$1" stdout -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" --psm "${2:-7}" --oem 1 -c tessedit_char_whitelist="${3:-0123456789}" -c classify_bln_numeric_mode=1 2>/dev/null | tr -d '\r'; }

# Нормализация распознанного кода
normalize_code_tail(){
  local raw="${1:-}"
  local d; d="$(echo "$raw" | tr -cd '0123456789')"
  case "$d" in
    *180) echo "1.8.0"; return ;;
    *280) echo "2.8.0"; return ;;
  esac
  local s; s="$(echo "$raw" | tr -cd '0128.')"    # только 1,2,8,0 и точки
  echo "$s" | grep -q "1\.8\.0" && { echo "1.8.0"; return; }
  echo "$s" | grep -q "2\.8\.0" && { echo "2.8.0"; return; }
  echo ""
}

read_code_relaxed(){ # $1=code-crop.jpg -> echo "1.8.0|2.8.0|"
  local in="${1:-}" a b raw="" norm=""
  a="$(mktemp --suffix=.png)"; b="$(mktemp --suffix=.png)"
  pp_code_A "$in" "$a"
  raw="$(ocr_txt "$a" 7 '0128.')" || true
  norm="$(normalize_code_tail "$raw")"
  if [ -z "$norm" ]; then
    raw="$(ocr_txt "$a" 8 '0128.')" || true
    norm="$(normalize_code_tail "$raw")"
  fi
  if [ -z "$norm" ]; then
    pp_code_B "$in" "$b"
    raw="$(ocr_txt "$b" 7 '0128.')" || true
    norm="$(normalize_code_tail "$raw")"
    if [ -z "$norm" ]; then
      raw="$(ocr_txt "$b" 8 '0128.')" || true
      norm="$(normalize_code_tail "$raw")"
    fi
  fi
  rm -f "$a" "$b"
  if normalize_bool "$DEBUG"; then
    local raw1; raw1="$(echo -n "$raw" | tr '\n' ' ' | tr -d '\r')"
    log_debug "RAW_CODE='${raw1}' -> NORM='${norm}'"
  fi
  echo "$norm"
}

# --- вспомогательное: «срез справа» ---
chop_right_img(){ # $1=in $2=px $3=out
  local in="${1:-}" px="${2:-0}" out="${3:-}"
  if [ "${px:-0}" -gt 0 ]; then
    convert "$in" -gravity East -chop "${px}x0" "$out"
  else
    cp "$in" "$out"
  fi
}

# --- читаем значение (один best из A/B препроцессов) ---
read_value_pair_best(){ # $1=in.jpg $2=prev_int -> echo digits
  local in="${1:-}" prev="${2:-0}" a b vA="" vB="" best=""
  a="$(mktemp --suffix=.png)"; b="$(mktemp --suffix=.png)"
  pp_val_A "$in" "$a"; vA="$(digits "$(ocr_txt "$a" 7 '0123456789')")"
  pp_val_B "$in" "$b"; vB="$(digits "$(ocr_txt "$b" 7 '0123456789')")"
  rm -f "$a" "$b"
  if [ -n "$vA" ] && [ "$vA" = "$vB" ]; then echo "$vA"; return; fi
  if [ -n "$vA" ] && [ -z "$vB" ]; then echo "$vA"; return; fi
  if [ -z "$vA" ] && [ -n "$vB" ]; then echo "$vB"; return; fi
  local iA iB dA dB; iA="$(intval "$vA")"; iB="$(intval "$vB")"
  dA=$(( iA>prev ? iA-prev : prev-iA )); dB=$(( iB>prev ? iB-prev : prev-iB ))
  if [ "$dA" -le "$dB" ]; then best="$vA"; else best="$vB"; fi
  echo "$best"
}

# --- новый: читаем значение двумя способами (normal & chopped-right) и выбираем лучший ---
read_value_best(){ # $1=value.jpg $2=prev_int -> echo digits
  local in="${1:-}" prev="${2:-0}" norm_png chop_png v_norm v_chop
  norm_png="$(mktemp --suffix=.png)"
  chop_png="$(mktemp --suffix=.png)"
  # базовый + срез справа
  cp "$in" "$norm_png"
  chop_right_img "$in" "$VALUE_CHOP_RIGHT" "$chop_png"

  v_norm="$(read_value_pair_best "$norm_png" "$prev")"
  v_chop="$(read_value_pair_best "$chop_png" "$prev")"

  rm -f "$norm_png" "$chop_png"

  # эвристика «хвостовая 1»
  if [ -n "$v_norm" ] && [ -n "$v_chop" ]; then
    if [ "${v_norm: -1}" = "1" ] && [ "${v_norm%1}" = "$v_chop" ]; then
      echo "$v_chop"; return
    fi
    if [ "${v_chop: -1}" = "1" ] && [ "${v_chop%1}" = "$v_norm" ]; then
      echo "$v_norm"; return
    fi
  fi

  # выбор по близости к prev
  if [ -z "$v_norm" ]; then echo "$v_chop"; return; fi
  if [ -z "$v_chop" ]; then echo "$v_norm"; return; fi
  local inorm ichop dnorm dchop
  inorm="$(intval "$v_norm")"; ichop="$(intval "$v_chop")"
  dnorm=$(( inorm>prev ? inorm-prev : prev-inorm ))
  dchop=$(( ichop>prev ? ichop-prev : prev-ichop ))
  if [ "$dchop" -lt "$dnorm" ]; then echo "$v_chop"; else echo "$v_norm"; fi
}

# Обрезка длины значения под конкретный код
clamp_digits_for_code(){
  local _code="${1:-1.8.0}" s="${2:-}" min max len
  if [ "$_code" = "1.8.0" ]; then min="$VAL_MIN_1_8_0"; max="$VAL_MAX_1_8_0"; else min="$VAL_MIN_2_8_0"; max="$VAL_MAX_2_8_0"; fi
  len=${#s}
  if [ "$len" -gt "$max" ]; then s="${s:0:$max}"; fi   # важное изменение: берём ЛЕВЫЕ max цифр (отсекаем «хвост»)
  len=${#s}
  if [ "$len" -lt "$min" ]; then echo ""; return; fi
  echo "$s"
}

############################
# Принятие/публикация
############################
should_accept_value(){ # $1=code $2=new_s (digits) -> YES|NO:*
  local _code="${1:-}" _new_s="${2:-}"
  [ -z "$_code" ] && { echo "NO:nocode"; return; }
  [ -z "$_new_s" ] && { echo "NO:empty"; return; }
  local len=${#_new_s}; if [ "$len" -lt 3 ] || [ "$len" -gt 9 ]; then echo "NO:len"; return; fi
  local cname; cname="$(echo "$_code" | tr . _ )"
  local line last_s="" last_ts=0 now_ts
  line="$(load_state_pair "$cname")"
  if [ -n "$line" ]; then last_s="${line%% *}"; last_ts="${line##* }"; fi
  now_ts=$(date +%s)

  if [ -z "$last_s" ] && ! normalize_bool "$DOUBLE_CONFIRM"; then echo "YES:first"; return; fi

  local last_i; last_i=$(intval "$last_s")
  local new_i;  new_i=$(intval "$_new_s")

  if [ "$last_i" -gt 0 ] && [ "$new_i" -lt "$last_i" ]; then echo "NO:monotonic"; return; fi

  local dt=$(( now_ts - last_ts )); [ "$dt" -lt 1 ] && dt=1
  local allowed; allowed="$(allowed_jump_units "$_code" "$dt")"
  local diff=$(( new_i - last_i ))
  if [ "$last_i" -gt 0 ] && [ "$diff" -gt "$allowed" ]; then echo "NO:jump($diff>$allowed)"; return; fi

  echo "YES:ok"
}

publish_value(){
  local _code="${1:-1.8.0}" _value="${2:-0}" topic payload ts
  ts=$(date --iso-8601=seconds)
  payload=$(printf '{"code":"%s","value":"%s","timestamp":"%s"}' "$_code" "$_value" "$ts")
  if [ "$_code" = "1.8.0" ]; then topic="$MQTT_TOPIC_1"; else topic="$MQTT_TOPIC_2"; fi
  log_debug "MQTT $_code: $payload"
  with_timeout 5 mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$topic" -m "$payload" || log_error "mqtt publish failed"
  save_state_pair "$(echo "$_code" | tr . _ )" "$_value" "$(date +%s)"
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

  CODE_NORM=""
  for ((i=1; i<=CODE_BURST_TRIES; i++)); do
    log_debug "Скачивание скриншота… (try $i/$CODE_BURST_TRIES)"
    with_timeout 8 curl -fsSL --connect-timeout 5 --max-time 7 -o "$SCRIPT_DIR/full.jpg" "$CAMERA_URL" || true
    if [ ! -s "$SCRIPT_DIR/full.jpg" ]; then
      log_error "Не удалось получить full.jpg"
      sleep "$SLEEP_INTERVAL"
      continue
    fi

    CODE_ROI=$(pad_roi_y "$(shift_roi "$CODE_CROP")"  "$PADY_CODE")
    VALUE_ROI=$(pad_roi_y "$(shift_roi "$VALUE_CROP")" "$PADY_VALUE")

    # КОД: кроп + опц. срез справа
    convert "$SCRIPT_DIR/full.jpg" -crop "$CODE_ROI" +repage "$SCRIPT_DIR/code.raw.jpg" || { log_error "КРОП code"; break; }
    if [ "${CODE_CHOP_RIGHT:-0}" -gt 0 ]; then
      convert "$SCRIPT_DIR/code.raw.jpg" -gravity East -chop "${CODE_CHOP_RIGHT}x0" "$SCRIPT_DIR/code.jpg"
    else
      cp "$SCRIPT_DIR/code.raw.jpg" "$SCRIPT_DIR/code.jpg"
    fi

    CODE_NORM="$(read_code_relaxed "$SCRIPT_DIR/code.jpg")"
    log_debug "КОД='${CODE_NORM:-}' (try $i/$CODE_BURST_TRIES)"
    if [ -n "$CODE_NORM" ]; then break; fi
    sleep "$CODE_BURST_DELAY_S"
  done

  if [ -z "$CODE_NORM" ]; then
    log_debug "Код не распознан. Пропуск кадра."
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  # Значение — из того же кадра: кроп + опц. срез справа
  log_debug "Код принят ($CODE_NORM). Обрезка VALUE: $VALUE_ROI"
  convert "$SCRIPT_DIR/full.jpg" -crop "$VALUE_ROI" +repage "$SCRIPT_DIR/value.raw.jpg" || { log_error "КРОП value"; sleep "$SLEEP_INTERVAL"; continue; }
  if [ "${VALUE_CHOP_RIGHT:-0}" -gt 0 ]; then
    convert "$SCRIPT_DIR/value.raw.jpg" -gravity East -chop "${VALUE_CHOP_RIGHT}x0" "$SCRIPT_DIR/value.jpg"
  else
    cp "$SCRIPT_DIR/value.raw.jpg" "$SCRIPT_DIR/value.jpg"
  fi

  st_pair="$(load_state_pair "$(echo "$CODE_NORM" | tr . _ )")"
  prev_int=0; if [ -n "$st_pair" ]; then prev_int="$(intval "${st_pair%% *}")"; fi

  # ДВА ВАРИАНТА OCR значения и выбор лучшего
  CAND="$(read_value_best "$SCRIPT_DIR/value.jpg" "$prev_int")"
  # Ограничение длины: теперь обрезаем СЛЕВА->ПРАВО (оставляем левую часть), чтобы срубить «хвостовую 1»
  CAND="$(clamp_digits_for_code "$CODE_NORM" "$CAND")"
  if [ -z "$CAND" ]; then
    log_debug "DROP $CODE_NORM: неподходящая длина (после clamp)"
    sleep "$SLEEP_INTERVAL"; continue
  fi
  CAND="$(lstrip_zeros "$CAND")"

  verdict="$(should_accept_value "$CODE_NORM" "$CAND")"
  case "$verdict" in
    YES:*)       publish_value "$CODE_NORM" "$CAND"; published=1 ;;
    NO:pending)  log_debug "HOLD $CODE_NORM: ждём подтверждение ($CAND)" ;;
    NO:jump*)    log_debug "DROP $CODE_NORM: анти-скачок ($verdict)" ;;
    NO:monotonic)log_debug "DROP $CODE_NORM: нарушена монотонность" ;;
    NO:len)      log_debug "DROP $CODE_NORM: неподходящая длина" ;;
    NO:nocode)   log_debug "DROP: пустой код" ;;
    NO:empty|NO:*)log_debug "DROP $CODE_NORM: пусто/мусор" ;;
  esac

  if [ $published -eq 0 ]; then
    sleep "$SLEEP_INTERVAL"
  elif [ "$CODE_NORM" = "2.8.0" ]; then
    sleep "$EXTRA_PAUSE"
  fi
done
