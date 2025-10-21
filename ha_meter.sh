#!/bin/bash
# ha_meter.sh — OCR 7-segment + анти-скачок + двойное подтверждение

# ----- отладка и логирование (универсально для 1/0/true/false/yes/no/on/off) -----
DEBUG="${DEBUG:-1}"

normalize_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)  return 0 ;;  # истина
    0|false|no|off|"") return 1 ;;  # ложь
    *)              return 0 ;;  # всё прочее трактуем как истину по-умолчанию
  esac
}

log_debug() { normalize_bool "$DEBUG" && echo "[DEBUG] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# ---------- чтение опций ----------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OPTS_FILE="/data/options.json"

# safe jq getter с дефолтами
jget_str(){ jq -r --arg k "$1" --arg def "$2" 'if has($k) and .[$k] != null then .[$k] else $def end' 2>/dev/null; }
jget_int(){ jq -r --arg k "$1" --argjson def "$2" 'if has($k) and .[$k] != null then .[$k] else $def end' 2>/dev/null; }
jget_num(){ jq -r --arg k "$1" --argjson def "$2" 'if has($k) and .[$k] != null then .[$k] else $def end' 2>/dev/null; }

if command -v jq >/dev/null 2>&1 && [ -f "$OPTS_FILE" ]; then
  DEBUG="$(jq -r '.debug // true' "$OPTS_FILE" 2>/dev/null)"

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

  STABLE_HITS="$(jq -r '.stable_hits // 2' "$OPTS_FILE")"
  PENDING_TTL_SEC="$(jq -r '.pending_ttl_sec // 60' "$OPTS_FILE")"

  TESS_LANG="$(jq -r '.tess_lang // "ssd_int"' "$OPTS_FILE")"
  STATE_DIR="$(jq -r '.state_dir // "/data/state"' "$OPTS_FILE")"
else
  # дефолты, если jq/опции недоступны
  CAMERA_URL="http://192.168.8.195/cgi-bin/CGIProxy.fcgi?cmd=snapPicture2&usr=admin&pwd=t1010113"
  CODE_CROP="64x23+576+361"
  VALUE_CROP="138x30+670+353"
  DX=0; DY=0; PADY_CODE=2; PADY_VALUE=3

  MQTT_HOST="192.168.8.20"; MQTT_USER="mqtt"; MQTT_PASSWORD="mqtt"
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

  STABLE_HITS=2
  PENDING_TTL_SEC=60

  TESS_LANG="ssd_int"
  STATE_DIR="$SCRIPT_DIR/state"
fi

mkdir -p "$STATE_DIR"
log_debug "Опции загружены. CAMERA_URL=$CAMERA_URL, CODE_CROP=$CODE_CROP, VALUE_CROP=$VALUE_CROP, DX/DY=${DX}/${DY}, DEBUG=$DEBUG"

# ----- дальше идёт твой уже согласованный устойчивый код -----
# (Весь остальной скрипт — тот, что я присылал целиком в предыдущем сообщении:
#  препро IM6 для кода/значения (3 ветки), Левенштейн, голосование,
#  анти-скачок с allowed_jump_units() c учётом DAILY_MAX_* и MAX_GAP_DAYS_CAP,
#  double-confirm с pending TTL, MQTT Discovery и публикацией.
#  Ничего менять не нужно — он просто использует переменные выше.)

# ... ВСТАВЬ сюда остальную часть ранее выданного полного ha_meter.sh без изменений ...
