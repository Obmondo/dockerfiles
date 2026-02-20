#! /usr/bin/env bash

set -x
set -eou pipefail
IFS=$'\n\t'

ERRORCOUNT=0
CLUSTER_NAME=${CLUSTER_NAME_LABEL:-"mariadb-cluster"}
LOGICAL_BACKUP_PROVIDER=${LOGICAL_BACKUP_PROVIDER:="s3"}
DUMP_SIZE_COEFF=5
ALL_DB_SIZE_QUERY="SELECT SUM(data_length + index_length) FROM information_schema.TABLES;"

function estimate_size {
  # Connects to MariaDB to calculate data size for S3 multipart upload optimization
  mariadb -h "$MARIADB_HOST" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
    --skip-ssl -Nsr -e "${ALL_DB_SIZE_QUERY}" < /dev/null
}

function dump {
  echo "Taking dump from ${MARIADB_HOST} using mariadb-dump for database ${MARIADB_DATABASE}" >&2
  mariadb-dump -h "$MARIADB_HOST" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -P "$MARIADB_PORT" \
    --single-transaction \
    --quick \
    --routines \
    --events \
    --insert-ignore \
    --verbose \
    "$MARIADB_DATABASE"
}

function compress {
  # Use pigz for multi-threaded compression if available, else gzip
  command -v pigz >/dev/null 2>&1 && pigz || gzip

}

function generate_checksum {
  local FILE_PATH="${1}"
  local CHECKSUM_FILE="/tmp/checksum.sha1"

  echo "Generating SHA1 checksum for ${FILE_PATH}..."
  sha1sum "${FILE_PATH}" | tee "${CHECKSUM_FILE}"
}

function aws_upload {
  EXPECTED_SIZE=$(stat -c%s /tmp/final_upload.sql.gz)
  PATH_TO_BACKUP="s3://${LOGICAL_BACKUP_S3_BUCKET}/${CLUSTER_NAME}/${LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX}/logical_backups/$(date +%s).sql.gz"

  args=()
  [[ -n "${EXPECTED_SIZE}" ]] && args+=("--expected-size=${EXPECTED_SIZE}")
  [[ -n "${LOGICAL_BACKUP_S3_ENDPOINT}" ]] && args+=("--endpoint-url=${LOGICAL_BACKUP_S3_ENDPOINT}")
  [[ -n "${LOGICAL_BACKUP_S3_REGION}" ]] && args+=("--region=${LOGICAL_BACKUP_S3_REGION}")

  aws s3 cp /tmp/final_upload.sql.gz "$PATH_TO_BACKUP" "${args[@]}"
}


if [ "$LOGICAL_BACKUP_PROVIDER" == "az" ]; then
  echo "Uploading to Azure Blob Storage..."
else  
    dump 2> /tmp/dump_stderr.log | tee /tmp/raw_dump.sql | compress > /tmp/final_upload.sql.gz
    PIPELINE_STATUS=("${PIPESTATUS[@]}")
    generate_checksum /tmp/final_upload.sql.gz
    aws_upload
    sleep 1000

    [[ ${PIPELINE_STATUS[0]} != 0 || ${PIPELINE_STATUS[1]} != 0 || ${PIPELINE_STATUS[2]} != 0 ]] && (( ERRORCOUNT += 1 ))
    exit $ERRORCOUNT
fi