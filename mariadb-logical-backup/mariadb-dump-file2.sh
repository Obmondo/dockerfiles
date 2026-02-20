#! /usr/bin/env bash

set -x
set -eou pipefail
IFS=$'\n\t'

ERRORCOUNT=0
CLUSTER_NAME=${CLUSTER_NAME_LABEL:-"mariadb-cluster"}
LOGICAL_BACKUP_PROVIDER=${LOGICAL_BACKUP_PROVIDER:="s3"}

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

if [ "$LOGICAL_BACKUP_PROVIDER" == "az" ]; then
  echo "Uploading to Azure Blob Storage..."
else  
    dump 2> /tmp/dump_stderr.log | tee /tmp/raw_dump.sql | compress > /tmp/final_upload.sql.gz
    PIPELINE_STATUS=("${PIPESTATUS[@]}")
    generate_checksum /tmp/final_upload.sql.gz
    sleep 1000

    [[ ${PIPELINE_STATUS[0]} != 0 || ${PIPELINE_STATUS[1]} != 0 || ${PIPELINE_STATUS[2]} != 0 ]] && (( ERRORCOUNT += 1 ))
    exit $ERRORCOUNT
fi