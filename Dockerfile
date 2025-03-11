FROM debian:bullseye-slim

# Обновляем списки пакетов и устанавливаем необходимые утилиты:
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tesseract-ocr \
      imagemagick \
      curl \
      mosquitto-clients && \
    rm -rf /var/lib/apt/lists/*

# Копируем скрипт запуска и файл обученной модели
COPY ha_meter.sh /ha_meter.sh
COPY ssd_int.traineddata /ssd_int.traineddata
RUN chmod +x /ha_meter.sh

# Запускаем скрипт старта
CMD ["/ha_meter.sh"]
