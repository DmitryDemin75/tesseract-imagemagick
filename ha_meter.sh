#!/usr/bin/env bash
# ha_meter.sh — OCR 7-seg: код по шаблонам (RMSE) + строгий OCR, VALUE с кворумом голосов + double-confirm + анти-скачок
# VALUE всегда из того же кадра, что и код.

###############################################################################
# Отладка/логирование
###############################################################################
DEBUG="${DEBUG:-1}"
normalize_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)  return 0 ;;
    0|false|no|off|"") return 1 ;;
    *) return 0 ;;
  esac
}
LOG_TO_FILE=false
LOG_FILE=""
log_write_file(){ if normalize_bool "$LOG_TO_FILE"; then [ -n "$LOG_FILE" ] && echo "$1" >> "$LOG_FILE"; fi; }
log_debug(){ local msg="[DEBUG] $*"; normalize_bool "$DEBUG" && echo "$msg"; log_write_file "$msg"; }
log_error(){ local msg="[ERROR] $*"; echo "$msg" >&2; log_write_file "$msg"; }

###############################################################################
# Чтение опций
###############################################################################
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OPTS_FILE="/data/options.json"

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
  STABLE_HITS_COLD="$(jq -r '.stable_hits_cold // 3' "$OPTS_FILE")"
  PENDING_TTL_SEC="$(jq -r '.pending_ttl_sec // 60' "$OPTS_FILE")"

  CODE_STRICT="$(jq -r '.code_strict // true' "$OPTS_FILE")"
  CODE_GATE_ENABLED="$(jq -r '.code_gate_enabled // false' "$OPTS_FILE")"
  CODE_STABLE_HITS="$(jq -r '.code_stable_hits // 2' "$OPTS_FILE")"
  CODE_PENDING_TTL_SEC="$(jq -r '.code_pending_ttl_sec // 5' "$OPTS_FILE")"

  CODE_BURST_TRIES="$(jq -r '.code_burst_tries // 3' "$OPTS_FILE")"
  CODE_BURST_DELAY_S="$(jq -r '.code_burst_delay_s // 0.15' "$OPTS_FILE")"

  CODE_TPL_THR="$(jq -r '.code_template_threshold // 0.22' "$OPTS_FILE")"
  CODE_TPL_MARGIN="$(jq -r '.code_template_margin // 0.04' "$OPTS_FILE")"

  VALUE_VOTE_QUORUM="$(jq -r '.value_vote_quorum // 2' "$OPTS_FILE")"

  TESS_LANG="$(jq -r '.tess_lang // "ssd_int"' "$OPTS_FILE")"
  STATE_DIR="$(jq -r '.state_dir // "/data/state"' "$OPTS_FILE")"

  CALIBRATE_DUMP="$(jq -r '.calibrate_dump // false' "$OPTS_FILE")"
  DUMP_DIR="$(jq -r '.dump_dir // "/share/ocr-debug"' "$OPTS_FILE")"

  LOG_TO_FILE="$(jq -r '.log_to_file // true' "$OPTS_FILE")"
  LOG_FILE="$(jq -r '.log_file // "/data/ha_meter.log"' "$OPTS_FILE")"
  LOG_TRUNCATE_ON_START="$(jq -r '.log_truncate_on_start // true' "$OPTS_FILE")"
else
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
  STABLE_HITS_COLD=3
  PENDING_TTL_SEC=60

  CODE_STRICT=true
  CODE_GATE_ENABLED=false
  CODE_STABLE_HITS=2
  CODE_PENDING_TTL_SEC=5

  CODE_BURST_TRIES=3
  CODE_BURST_DELAY_S=0.15

  CODE_TPL_THR=0.22
  CODE_TPL_MARGIN=0.04

  VALUE_VOTE_QUORUM=2

  TESS_LANG="ssd_int"
  STATE_DIR="$SCRIPT_DIR/state"

  CALIBRATE_DUMP=false
  DUMP_DIR="/share/ocr-debug"

  LOG_TO_FILE=true
  LOG_FILE="/data/ha_meter.log"
  LOG_TRUNCATE_ON_START=true
fi

# Нормализуем DEBUG в 1/0 и готовим лог
normalize_bool "$DEBUG" && DEBUG=1 || DEBUG=0
if normalize_bool "$LOG_TO_FILE"; then
  mkdir -p "$(dirname "$LOG_FILE")"
  if normalize_bool "$LOG_TRUNCATE_ON_START"; then : > "$LOG_FILE"; echo "[DEBUG] Локальный лог очищен: $LOG_FILE" >> "$LOG_FILE"; else touch "$LOG_FILE"; fi
fi

log_debug "Опции загружены. CAMERA_URL=$CAMERA_URL, CODE_CROP=$CODE_CROP, VALUE_CROP=$VALUE_CROP, DX/DY=${DX}/${DY}, DEBUG=$DEBUG"

###############################################################################
# Утилиты/таймауты/ROI
###############################################################################
parse_roi(){ local r="$1"; local W=${r%%x*}; local rest=${r#*x}; local H=${rest%%+*}; local t=${r#*+}; local X=${t%%+*}; local Y=${r##*+}; echo "$W $H $X $Y"; }
fmt_roi(){ echo "${1}x${2}+${3}+${4}"; }
shift_roi(){ read -r W H X Y < <(parse_roi "$1"); fmt_roi "$W" "$H" "$((X+DX))" "$((Y+DY))"; }
pad_roi_y(){ local roi="$1" pad="$2"; read -r W H X Y < <(parse_roi "$roi"); fmt_roi "$W" "$((H+2*pad))" "$X" "$((Y-pad))"; }
intval(){ echo "$1" | awk '{if($0=="") print 0; else print int($0+0)}'; }

TIMEOUT_BIN="$(command -v timeout || true)"
with_timeout(){ local sec="$1"; shift; if [ -n "$TIMEOUT_BIN" ]; then $TIMEOUT_BIN "$sec" "$@"; else "$@"; fi }

###############################################################################
# Состояние/ pending
###############################################################################
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/state}"
mkdir -p "$STATE_DIR"

tpl_18="$STATE_DIR/tpl_1_8_0.png"
tpl_28="$STATE_DIR/tpl_2_8_0.png"

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

load_code_pending(){ local f="$STATE_DIR/pending_code.txt"; [ -s "$f" ] && cat "$f" || echo ""; }
save_code_pending(){ local code="$1" ts="${2:-$(date +%s)}" hits="${3:-1}"; echo "${code}|${ts}|${hits}" > "$STATE_DIR/pending_code.txt"; }
clear_code_pending(){ rm -f "$STATE_DIR/pending_code.txt" 2>/dev/null || true; }

###############################################################################
# Инициализация из retained (если локального state нет)
###############################################################################
if command -v mosquitto_sub >/dev/null 2>&1; then
  if [ ! -s "$STATE_DIR/last_1_8_0.txt" ]; then
    v=$(with_timeout 5 mosquitto_sub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -C 1 -R -t "$MQTT_TOPIC_1" | awk -F'"' '/"value":/ {print $(NF-3)}' | tr -cd '0-9')
    [ -n "$v" ] && echo -n "${v}|$(date +%s)" > "$STATE_DIR/last_1_8_0.txt"
  fi
  if [ ! -s "$STATE_DIR/last_2_8_0.txt" ]; then
    v=$(with_timeout 5 mosquitto_sub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -C 1 -R -t "$MQTT_TOPIC_2" | awk -F'"' '/"value":/ {print $(NF-3)}' | tr -cd '0-9')
    [ -n "$v" ] && echo -n "${v}|$(date +%s)" > "$STATE_DIR/last_2_8_0.txt"
  fi
fi

###############################################################################
# Левенштейн (больше не используем для кода; оставил на всякий случай)
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
# Препроцесс (IM6)
###############################################################################
# Код → бинарное изображение фиксированного размера для шаблонов
pp_code_bin(){ convert "$1" -auto-orient -colorspace Gray -resize 350% -contrast-stretch 1%x1% -gamma 1.00 -threshold 60% -type bilevel -resize 240x64\! "$2"; }
pp_code_alt(){ convert "$1" -auto-orient -colorspace Gray -resize 350% -clahe 40x40+10+2 -adaptive-threshold 29x29+8% -type bilevel -resize 240x64\! "$2" 2>/dev/null || cp "$1" "$2"; }

pp_val_A(){ convert "$1" -auto-orient -colorspace Gray -clahe 64x64+10+2 -sigmoidal-contrast 6x50% -deskew 40% -resize 300% -adaptive-threshold 41x41+8% -type bilevel -morphology Close Diamond:1 "$2" 2>/dev/null || cp "$1" "$2"; }
pp_val_B(){ convert "$1" -colorspace Gray -auto-level -contrast-stretch 0.5%x0.5% -gamma 1.10 -resize 300% -threshold 52% -type bilevel "$2"; }
pp_val_C(){ convert "$1" -colorspace Gray -auto-level -contrast-stretch 0.3%x0.3% -gamma 1.05 -resize 320% -threshold 58% -type bilevel "$2"; }

###############################################################################
# OCR
###############################################################################
ocr_txt(){ tesseract "$1" stdout -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" --psm "$2" --oem 1 -c tessedit_char_whitelist="$3" -c classify_bln_numeric_mode=1 2>/dev/null | tr -d '\r'; }
ocr_code_strict(){
  local img="$1" uw out
  uw="$(mktemp --suffix=.words)"; printf "1.8.0\n2.8.0\n" > "$uw"
  out="$(tesseract "$img" stdout -l "$TESS_LANG" --tessdata-dir "$SCRIPT_DIR" --psm 8 --oem 1 \
        --user-words "$uw" -c load_system_dawg=F -c load_freq_dawg=F -c tessedit_char_whitelist=0128. 2>/dev/null | tr -d '\r' | xargs || true)"
  rm -f "$uw"
  case "$out" in "1.8.0"|"2.8.0") echo "$out" ;; *) echo "" ;; esac
}
digits(){ echo "$1" | tr -cd '0-9'; }

###############################################################################
# Шаблонное сравнение кода (ImageMagick compare -metric RMSE)
###############################################################################
has_compare(){ command -v compare >/dev/null 2>&1; }
diff_score(){ # печатает нормализованный RMSE (в скобках)
  local a="$1" b="$2"
  compare -metric RMSE "$a" "$b" null: 2>&1 | awk -F'[()]' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}'
}
code_by_templates(){
  local bin="$1" best="" s18="" s28=""
  has_compare || { echo ""; return; }
  [ -s "$tpl_18" ] || [ -s "$tpl_28" ] || { echo ""; return; }

  if [ -s "$tpl_18" ]; then s18="$(diff_score "$bin" "$tpl_18" 2>/dev/null || echo "")"; fi
  if [ -s "$tpl_28" ]; then s28="$(diff_score "$bin" "$tpl_28" 2>/dev/null || echo "")"; fi
  [ -z "$s18$s28" ] && { echo ""; return; }

  # Чем меньше RMSE — тем похожее
  local thr="${CODE_TPL_THR:-0.22}" margin="${CODE_TPL_MARGIN:-0.04}"
  if [ -n "$s18" ] && { awk -v x="$s18" -v t="$thr" 'BEGIN{exit !(x<t)}'; }; then
    if [ -n "$s28" ]; then
      # нужна разница больше margin
      awk -v a="$s28" -v b="$s18" -v m="$margin" 'BEGIN{exit !((a-b)>m)}' && best="1.8.0"
    else
      best="1.8.0"
    fi
  fi
  if [ -z "$best" ] && [ -n "$s28" ] && { awk -v x="$s28" -v t="$thr" 'BEGIN{exit !(x<t)}'; }; then
    if [ -n "$s18" ]; then
      awk -v a="$s18" -v b="$s28" -v m="$margin" 'BEGIN{exit !((a-b)>m)}' && best="2.8.0"
    else
      best="2.8.0"
    fi
  fi

  if normalize_bool "$DEBUG"; then
    [ -n "$s18" ] && log_debug "TMPL RMSE: 1.8.0=$s18"
    [ -n "$s28" ] && log_debug "TMPL RMSE: 2.8.0=$s28"
    [ -n "$best" ] && log_debug "TMPL PICK: $best"
  fi
  echo "$best"
}
save_template_if_missing(){
  local code="$1" bin="$2"
  if [ "$code" = "1.8.0" ] && [ ! -s "$tpl_18" ]; then cp "$bin" "$tpl_18"; log_debug "Template saved: $tpl_18"; fi
  if [ "$code" = "2.8.0" ] && [ ! -s "$tpl_28" ]; then cp "$bin" "$tpl_28"; log_debug "Template saved: $tpl_28"; fi
}

###############################################################################
# Чтение значения с кворумом голосов
###############################################################################
read_value_votes(){ # $1=img $2=prev_value_int => echo "<best> <votes> <total>"
  local in="$1" prev="$2"
  local a="$(mktemp --suffix=.png)" b="$(mktemp --suffix=.png)" c="$(mktemp --suffix=.png)"
  pp_val_A "$in" "$a"; local vA="$(digits "$(ocr_txt "$a" 7 '0123456789')")"
  pp_val_B "$in" "$b"; local vB="$(digits "$(ocr_txt "$b" 7 '0123456789')")"
  pp_val_C "$in" "$c"; local vC="$(digits "$(ocr_txt "$c" 7 '0123456789')")"
  rm -f "$a" "$b" "$c"
  local total=0; [ -n "$vA" ] && total=$((total+1)); [ -n "$vB" ] && total=$((total+1)); [ -n "$vC" ] && total=$((total+1))

  # голосование
  local best=""; local votes=0
  for cand in "$vA" "$vB" "$vC"; do
    [ -z "$cand" ] && continue
    local cnt=0; [ "$cand" = "$vA" ] && cnt=$((cnt+1)); [ "$cand" = "$vB" ] && cnt=$((cnt+1)); [ "$cand" = "$vC" ] && cnt=$((cnt+1))
    if [ "$cnt" -gt "$votes" ]; then best="$cand"; votes="$cnt"; fi
  done

  # если кворум не набран — берём ближайшее к предыдущему
  if [ -z "$best" ] || [ "$votes" -lt 2 ]; then
    local bestv=""; local bestd=999999999; local vi d
    for v in "$vA" "$vB" "$vC"; do
      [ -z "$v" ] && continue
      vi=$(intval "$v"); d=$(( vi>prev ? vi-prev : prev-vi ))
      if [ "$d" -lt "$bestd" ]; then bestd="$d"; bestv="$v"; fi
    done
    [ -n "$bestv" ] && { best="$bestv"; votes=1; }
  fi

  echo "$best $votes $total"
}

###############################################################################
# Анти-скачок и публикация
###############################################################################
allowed_jump_units(){ # $1=code $2=dt_sec
  local code="$1" dt="$2"
  [ "$dt" -lt 1 ] && dt=1
  local dt_cap=$(( MAX_GAP_DAYS_CAP * 86400 ))
  [ "$dt" -gt "$dt_cap" ] && dt="$dt_cap"
  local kwh_day
  if [ "$code" = "1.8.0" ]; then
    kwh_day="$DAILY_MAX_KWH_1_8_0"
  else
    kwh_day="$DAILY_MAX_KWH_2_8_0"
  fi
  local allowed
  allowed="$(awk -v dt="$dt" -v kwh="$kwh_day" -v burst="$BURST_MULT" -v dec="$VALUE_DECIMALS" 'BEGIN{ s=1; for(i=0;i<dec;i++) s*=10; v=kwh*(dt/86400.0)*s*burst; if(v<1)v=1; printf("%.0f",v); }')"
  [ "$allowed" -lt "$MIN_STEP_UNITS" ] && echo "$MIN_STEP_UNITS" || echo "$allowed"
}

publish_value(){
  local code="$1" value="$2" topic payload ts
  ts=$(date --iso-8601=seconds)
  payload=$(printf '{"code":"%s","value":"%s","timestamp":"%s"}' "$code" "$value" "$ts")
  if [ "$code" = "1.8.0" ]; then topic="$MQTT_TOPIC_1"; else topic="$MQTT_TOPIC_2"; fi
  log_debug "MQTT $code: $payload"
  with_timeout 5 mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$topic" -m "$payload" || log_error "pub $code"
  save_state_pair "$(echo "$code" | tr . _ )" "$value" "$(date +%s)"
}

###############################################################################
# should_accept() — VALUE; should_accept_code() — опционально
###############################################################################
should_accept(){
  local code="$1" new_s="$2"
  [ -z "$new_s" ] && { echo "NO:empty"; return; }
  local len=${#new_s}; if [ "$len" -lt 3 ] || [ "$len" -gt 9 ]; then echo "NO:len"; return; fi

  local cname; cname="$(echo "$code" | tr . _ )"
  local line last_s="" last_ts=0 now_ts
  line="$(load_state_pair "$cname")"
  if [ -n "$line" ]; then last_s="${line%% *}"; last_ts="${line##* }"; fi

  now_ts=$(date +%s)

  # Cold start
  if [ -z "$last_s" ]; then
    local p pv rest pts phits age
    p="$(load_pending "$cname")"
    if [ -n "$p" ]; then
      pv="${p%%|*}"; rest="${p#*|}"; pts="${rest%%|*}"; phits="${rest#*|}"; [ "$phits" = "$pts" ] && phits=1
      age=$(( now_ts - pts ))
      if [ "$pv" = "$new_s" ] && [ "$age" -le "$PENDING_TTL_SEC" ]; then
        phits=$(( phits + 1 ))
        if [ "$phits" -ge "$STABLE_HITS_COLD" ]; then
          clear_pending "$cname"; echo "YES:confirmed"; return
        else
          save_pending "$cname" "$new_s" "$pts" "$phits"; echo "NO:pending"; return
        fi
      fi
    fi
    save_pending "$cname" "$new_s"; echo "NO:pending"; return
  fi

  # Обычный режим
  local last_i; last_i=$(intval "$last_s")
  local new_i;  new_i=$(intval "$new_s")

  if [ "$last_i" -gt 0 ] && [ "$new_i" -lt "$last_i" ]; then echo "NO:monotonic"; return; fi

  local dt=$(( now_ts - last_ts )); [ "$dt" -lt 1 ] && dt=1
  local allowed; allowed=$(allowed_jump_units "$code" "$dt")
  local diff=$(( new_i - last_i ))
  if [ "$last_i" -gt 0 ] && [ "$diff" -gt "$allowed" ]; then echo "NO:jump($diff>$allowed)"; return; fi

  local p pv rest pts phits age
  p="$(load_pending "$cname")"
  if [ -n "$p" ]; then
    pv="${p%%|*}"; rest="${p#*|}"; pts="${rest%%|*}"; phits="${rest#*|}"; [ "$phits" = "$pts" ] && phits=1
    age=$(( now_ts - pts ))
    if [ "$pv" = "$new_s" ] && [ "$age" -le "$PENDING_TTL_SEC" ]; then
      phits=$(( phits + 1 ))
      if [ "$phits" -ge "$STABLE_HITS" ]; then
        clear_pending "$cname"; echo "YES:confirmed"; return
      else
        save_pending "$cname" "$new_s" "$pts" "$phits"; echo "NO:pending"; return
      fi
    fi
  fi
  save_pending "$cname" "$new_s"
  echo "NO:pending"
}

should_accept_code(){
  local nc="$1"
  [ -z "$nc" ] && { echo "NO:empty"; return; }
  local p pv rest pts phits now_ts age
  p="$(load_code_pending)"
  now_ts="$(date +%s)"
  if [ -n "$p" ]; then
    pv="${p%%|*}"; rest="${p#*|}"; pts="${rest%%|*}"; phits="${rest#*|}"; [ "$phits" = "$pts" ] && phits=1
    age=$(( now_ts - pts ))
    if [ "$pv" = "$nc" ] && [ "$age" -le "$CODE_PENDING_TTL_SEC" ]; then
      phits=$(( phits + 1 ))
      if [ "$phits" -ge "$CODE_STABLE_HITS" ]; then
        clear_code_pending; echo "YES:confirmed"; return
      else
        save_code_pending "$nc" "$pts" "$phits"; echo "NO:pending($phits/$CODE_STABLE_HITS)"; return
      fi
    fi
  fi
  save_code_pending "$nc"; echo "NO:pending(1/$CODE_STABLE_HITS)"
}

###############################################################################
# MQTT Discovery (retained)
###############################################################################
config_payload_1='{"name":"Energy Meter 1.8.0","state_topic":"'"$MQTT_TOPIC_1"'","unique_id":"energy_meter_1_8_0","unit_of_measurement":"kWh","value_template":"{{ value_json.value }}","json_attributes_topic":"'"$MQTT_TOPIC_1"'"}'
config_payload_2='{"name":"Energy Meter 2.8.0","state_topic":"'"$MQTT_TOPIC_2"'","unique_id":"energy_meter_2_8_0","unit_of_measurement":"kWh","value_template":"{{ value_json.value }}","json_attributes_topic":"'"$MQTT_TOPIC_2"'"}'

log_debug "Публикация конфигурации MQTT Discovery…"
with_timeout 5 mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_1" -m "$config_payload_1" || log_error "discovery 1.8.0"
with_timeout 5 mosquitto_pub -r -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_CONFIG_TOPIC_2" -m "$config_payload_2" || log_error "discovery 2.8.0"

###############################################################################
# Основной цикл
###############################################################################
while true; do
  published=0
  CODE_NORM=""
  DPI=72

  # ------ BURST: несколько быстрых попыток поймать кадр с кодом ------
  for ((i=1; i<=CODE_BURST_TRIES; i++)); do
    log_debug "Скачивание скриншота… (try $i/$CODE_BURST_TRIES)"
    with_timeout 8 curl -fsSL --connect-timeout 5 --max-time 7 -o "$SCRIPT_DIR/full.jpg" "$CAMERA_URL" || true
    if [ ! -s "$SCRIPT_DIR/full.jpg" ]; then
      log_error "Не удалось получить full.jpg"
      sleep "$SLEEP_INTERVAL"
      continue
    fi

    RAW_DPI=$(identify -format "%x" "$SCRIPT_DIR/full.jpg" 2>/dev/null || echo "")
    DPI=$(echo "$RAW_DPI" | sed 's/[^0-9.]//g'); [ -z "$DPI" ] && DPI=72
    log_debug "DPI: $DPI"

    CODE_ROI=$(pad_roi_y "$(shift_roi "$CODE_CROP")"  "$PADY_CODE")
    VALUE_ROI=$(pad_roi_y "$(shift_roi "$VALUE_CROP")" "$PADY_VALUE")

    # КОД
    log_debug "Обрезка CODE: $CODE_ROI"
    convert "$SCRIPT_DIR/full.jpg" -crop "$CODE_ROI" +repage "$SCRIPT_DIR/code.jpg" || { log_error "КРОП code"; break; }

    # подготавливаем бинарник для шаблонов
    bin1="$(mktemp --suffix=.png)"; bin2="$(mktemp --suffix=.png)"
    pp_code_bin "$SCRIPT_DIR/code.jpg" "$bin1"
    pp_code_alt "$SCRIPT_DIR/code.jpg" "$bin2"

    # 1) строгий OCR по bin1,bin2
    CODE_NORM="$(ocr_code_strict "$bin1")"
    [ -z "$CODE_NORM" ] && CODE_NORM="$(ocr_code_strict "$bin2")"

    # 2) шаблоны, если строгий не сработал
    if [ -z "$CODE_NORM" ]; then
      # пробуем оба препроцесса и сравниваем лучшую попытку
      local pick1 pick2
      pick1="$(code_by_templates "$bin1")"
      pick2="$(code_by_templates "$bin2")"
      if [ -n "$pick1" ] && [ -n "$pick2" ] && [ "$pick1" != "$pick2" ]; then
        # конфликт: считаем пусто (надёжность важнее)
        CODE_NORM=""
      else
        CODE_NORM="${pick1}${pick2}"
      fi
      [ "$CODE_NORM" = "12.8.0" ] && CODE_NORM="" # на всякий случай
      [ "$CODE_NORM" = "1.8.02.8.0" ] && CODE_NORM=""
    fi

    # 3) если строгий OCR дал точный код — сохраняем шаблон (если не было)
    if [ -n "$CODE_NORM" ]; then
      save_template_if_missing "$CODE_NORM" "$bin1"
    fi

    rm -f "$bin1" "$bin2"

    log_debug "КОД(best)='${CODE_NORM}' (try $i/$CODE_BURST_TRIES)"

    if [ -n "$CODE_NORM" ]; then
      # поймали кадр с кодом — на нём же считаем VALUE
      break
    fi

    sleep "$CODE_BURST_DELAY_S"
  done

  if [ -z "$CODE_NORM" ]; then
    log_debug "DROP CODE: пусто"
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  # Опциональный гейтинг по коду
  if normalize_bool "$CODE_GATE_ENABLED"; then
    cv="$(should_accept_code "$CODE_NORM")"
    case "$cv" in
      YES:*) : ;;
      NO:pending*) log_debug "HOLD CODE: ждём подтверждение кода ($cv)"; sleep "$SLEEP_INTERVAL"; continue ;;
      NO:empty|NO:*) log_debug "DROP CODE: код ненадёжен ($cv)"; sleep "$SLEEP_INTERVAL"; continue ;;
    esac
  fi

  # ЗНАЧЕНИЕ — из того же full.jpg
  log_debug "Код принят ($CODE_NORM). Обрезка VALUE: $VALUE_ROI"
  convert "$SCRIPT_DIR/full.jpg" -crop "$VALUE_ROI" +repage "$SCRIPT_DIR/value.jpg" || { log_error "КРОП value"; sleep "$SLEEP_INTERVAL"; continue; }
  if normalize_bool "$CALIBRATE_DUMP"; then mkdir -p "$DUMP_DIR"; cp "$SCRIPT_DIR/code.jpg" "$DUMP_DIR/code_last.jpg"; cp "$SCRIPT_DIR/value.jpg" "$DUMP_DIR/value_last.jpg"; fi

  st_pair="$(load_state_pair "$(echo "$CODE_NORM" | tr . _ )")"
  prev_int=0; if [ -n "$st_pair" ]; then prev_int="$(intval "${st_pair%% *}")"; fi

  read -r CAND VOTES TOTAL <<<"$(read_value_votes "$SCRIPT_DIR/value.jpg" "$prev_int")"
  [ -z "$CAND" ] && CAND="0"
  local quorum="${VALUE_VOTE_QUORUM:-2}"
  if [ "$VOTES" -lt "$quorum" ] && [ "$TOTAL" -ge 2 ]; then
    log_debug "VOTE $CODE_NORM: кворум не набран (cand=$CAND, votes=$VOTES/$TOTAL) → HOLD"
    verdict="NO:pending"
  else
    verdict="$(should_accept "$CODE_NORM" "$CAND")"
  fi

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
