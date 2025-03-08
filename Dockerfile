FROM debian:bullseye-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends tesseract-ocr imagemagick && \
    rm -rf /var/lib/apt/lists/*

COPY ha_meter.sh /ha_meter.sh
COPY ssd_int.traineddata /ssd_int.traineddata
RUN chmod +x /ha_meter.sh

CMD ["/ha_meter.sh"]
