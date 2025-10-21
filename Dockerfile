FROM debian:bullseye-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tesseract-ocr \
      imagemagick \
      curl \
      jq \
      coreutils \
      mosquitto-clients && \
    rm -rf /var/lib/apt/lists/*

# Скрипт и модель
COPY ha_meter.sh /ha_meter.sh
COPY ssd_int.traineddata /ssd_int.traineddata
RUN chmod +x /ha_meter.sh

CMD ["/ha_meter.sh"]
