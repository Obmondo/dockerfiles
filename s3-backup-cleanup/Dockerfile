FROM amazon/aws-cli:2.27.50
LABEL maintainer="Deepak Tiwari deepak@obmondo.com"

COPY ./s3-backup-cleanup/script/cleanup.sh /usr/local/bin/cleanup.sh
RUN chmod +x /usr/local/bin/cleanup.sh

ENV AWS_DEFAULT_REGION=us-east-1 \
    RETENTION_DAYS=30

ENTRYPOINT ["/usr/local/bin/cleanup.sh"]
