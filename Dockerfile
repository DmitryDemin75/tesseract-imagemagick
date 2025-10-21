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

# Копируем скрипт и обученную модель (лежит рядом с /ha_meter.sh)
COPY ha_meter.sh /ha_meter.sh
COPY ssd_int.traineddata /ssd_int.traineddata
RUN chmod +x /ha_meter.sh

# Точка входа
CMD ["/ha_meter.sh"]
