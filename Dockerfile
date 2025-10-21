FROM debian:bullseye-slim

# Обновление и установка зависимостей
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      jq \
      tesseract-ocr \
      imagemagick \
      curl \
      mosquitto-clients && \
    rm -rf /var/lib/apt/lists/*

# (необязательно) Подсказать tesseract, где лежат .traineddata
# В нашей версии скрипта используется --tessdata-dir "$SCRIPT_DIR", где SCRIPT_DIR="/"
# поэтому этот ENV не обязателен. Если захочешь — можно так:
# ENV TESSDATA_PREFIX=/

# Копируем скрипт и обученную модель
COPY ha_meter.sh /ha_meter.sh
COPY ssd_int.traineddata /ssd_int.traineddata
RUN chmod +x /ha_meter.sh

# Точка входа
CMD ["/ha_meter.sh"]
