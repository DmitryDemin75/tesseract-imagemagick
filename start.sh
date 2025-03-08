#!/bin/bash
# ha_meter.sh

# Определяем директорию скрипта, чтобы использовать её для .traineddata и хранения временных файлов.
SCRIPT_DIR=$(dirname "$0")

# URL камеры (скриншот)
CAMERA_URL="http://192.168.8.84:11080/endpoint/@scrypted/webhook/public/260/43f2d459c931e58b/takePicture"

# MQTT настройки
MQTT_HOST="192.168.8.20"
MQTT_USER="mqtt"
MQTT_PASSWORD="mqtt"
MQTT_TOPIC="homeassistant/sensor/energy_meter/state"

# Интервал между итерациями (сек)
SLEEP_INTERVAL=1

while true; do
  echo "Получение скриншота..."
  curl -s -o "$SCRIPT_DIR/full.jpg" "$CAMERA_URL"
  
  if [ ! -f "$SCRIPT_DIR/full.jpg" ]; then
    echo "Не удалось скачать изображение."
    sleep $SLEEP_INTERVAL
    continue
  fi

  echo "Обрезка изображений..."
  # Обрезаем область для кода: ширина 120, высота 44, координаты x=645, y=531
  convert "$SCRIPT_DIR/full.jpg" -crop 120x44+645+531 +repage "$SCRIPT_DIR/code.jpg"
  # Обрезаем область для значения: ширина 311, высота 69, координаты x=848, y=515
  convert "$SCRIPT_DIR/full.jpg" -crop 311x69+848+515 +repage "$SCRIPT_DIR/value.jpg"

  echo "Распознавание..."
  # Запускаем Tesseract с указанием каталога tessdata (то же, что и скрипт)
  code=$(tesseract "$SCRIPT_DIR/code.jpg" stdout -l ssd --tessdata-dir "$SCRIPT_DIR" --psm 7 -c tessedit_char_whitelist=0123456789.)
  value=$(tesseract "$SCRIPT_DIR/value.jpg" stdout -l ssd --tessdata-dir "$SCRIPT_DIR" --psm 7 -c tessedit_char_whitelist=0123456789.-)

  # Удаляем лишние пробелы
  code=$(echo "$code" | xargs)
  value=$(echo "$value" | xargs)

  # Получаем временную метку
  timestamp=$(date --iso-8601=seconds)

  # Формируем JSON-пейлоад для сенсора: основное состояние — value, атрибуты — код и временная метка
  payload=$(printf '{"state": "%s", "attributes": {"code": "%s", "timestamp": "%s"}}' "$value" "$code" "$timestamp")
  
  echo "Публикация MQTT: $payload"
  # Публикуем через mosquitto_pub с заданными учетными данными
  mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$MQTT_TOPIC" -m "$payload"
  
  sleep $SLEEP_INTERVAL
done
