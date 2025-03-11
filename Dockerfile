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
COPY tessdata/ssd_int.traineddata /tessdata/ssd_int.traineddata
#COPY tessdata/ssd.traineddata /tessdata/ssd.traineddata
RUN chmod +x /ha_meter.sh

# Запускаем скрипт старта
CMD ["/ha_meter.sh"]
