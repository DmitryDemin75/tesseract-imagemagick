FROM debian:bullseye-slim

# Обновляем и ставим зависимости
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tesseract-ocr \
      imagemagick \
      curl \
      mosquitto-clients \
      jq && \
    rm -rf /var/lib/apt/lists/*

# Копируем скрипт и обученную модель
COPY ha_meter.sh /ha_meter.sh
COPY ssd_int.traineddata /ssd_int.traineddata
RUN chmod +x /ha_meter.sh

# Запуск
CMD ["/ha_meter.sh"]
