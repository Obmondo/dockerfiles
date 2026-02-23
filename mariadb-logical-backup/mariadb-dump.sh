#! /usr/bin/env bash

set -x
set -eou pipefail
IFS=$'\n\t'

## Required Env passed from CronJob:
# MARIADB_HOST, MARIADB_USER, MARIADB_PASSWORD, MARIADB_DATABASE (or use .my.cnf)
# LOGICAL_BACKUP_PROVIDER, LOGICAL_BACKUP_S3_BUCKET, etc.

# MariaDB query to get total size of all databases in bytes
ALL_DB_SIZE_QUERY="SELECT SUM(data_length + index_length) FROM information_schema.TABLES;"
DUMP_SIZE_COEFF=5
ERRORCOUNT=0
CLUSTER_NAME=${CLUSTER_NAME_LABEL:-"mariadb-cluster"}
LOGICAL_BACKUP_PROVIDER=${LOGICAL_BACKUP_PROVIDER:="s3"}
LOGICAL_BACKUP_S3_RETENTION_TIME=${LOGICAL_BACKUP_S3_RETENTION_TIME:=""}
LOGICAL_BACKUP_S3_ENDPOINT=${LOGICAL_BACKUP_S3_ENDPOINT:-}
LOGICAL_BACKUP_S3_REGION=${LOGICAL_BACKUP_S3_REGION:-"us-west-1"}

function estimate_size {
  # Connects to MariaDB to calculate data size for S3 multipart upload optimization
  mariadb -h "$MARIADB_HOST" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
    --skip-ssl -Nsr -e "${ALL_DB_SIZE_QUERY}" < /dev/null
}

function dump {
  echo "Taking dump from ${MARIADB_HOST} using mariadb-dump for database ${MARIADB_DATABASE}" >&2
  
  # --all-databases: Backup everything
  # --single-transaction: Ensure consistency for InnoDB without locking
  # --quick: Stream output to save memory
  # --routines: Include stored procedures
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

function az_upload {
  local FILE_PATH="${1}"
  # Path: container/cluster-name/scope/logical_backups/timestamp.sql.gz
  PATH_TO_BACKUP="${CLUSTER_NAME}/${LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX}/logical_backups/$(date +%s).sql.gz"

  echo "Uploading to Azure Blob Storage..."
  az storage blob upload \
    --file "${FILE_PATH}" \
    --account-name "${LOGICAL_BACKUP_AZURE_STORAGE_ACCOUNT_NAME}" \
    --account-key "${LOGICAL_BACKUP_AZURE_STORAGE_ACCOUNT_KEY}" \
    --container-name "${LOGICAL_BACKUP_AZURE_STORAGE_CONTAINER}" \
    --name "${PATH_TO_BACKUP}"
}

function setup_mc_alias {
  local endpoint="${LOGICAL_BACKUP_S3_ENDPOINT:-https://s3.amazonaws.com}"
  echo "Setting up MinIO Client alias..."
  mc alias set minio_dest "$endpoint" "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}"
}

function mc_delete_outdated {
  if [[ -z "$LOGICAL_BACKUP_S3_RETENTION_TIME" ]] ; then
    echo "No retention time configured; skipping cleanup."
    return 0
  fi

  setup_mc_alias

  cutoff_timestamp=$(date -d "$LOGICAL_BACKUP_S3_RETENTION_TIME ago" +%s)
  prefix="${CLUSTER_NAME}/${LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX}/logical_backups/"
  bucket_path="minio_dest/${LOGICAL_BACKUP_S3_BUCKET}/${prefix}"

  mc ls --json "$bucket_path" | jq -r '.key' | awk -F/ '{print $NF}' | grep '\.sql\.gz$' | sort -n > /tmp/all-backups

  if [[ $(wc -l < /tmp/all-backups) -le 1 ]]; then
    echo "1 or fewer backups found, skipping cleanup."
    return 0
  fi

  awk -v cutoff="$cutoff_timestamp" -F. '{if ($1 < cutoff) print $0}' /tmp/all-backups > /tmp/outdated-backups
  
  most_recent=$(tail -n 1 /tmp/all-backups)
  sed -i "\|${most_recent}|d" /tmp/outdated-backups

  count=$(wc -l < /tmp/outdated-backups)
  if [[ $count -gt 0 ]]; then
    echo "Deleting $count outdated backups created before $cutoff_timestamp"
    for backup in $(cat /tmp/outdated-backups); do
      mc rm "$bucket_path$backup"
    done
  fi
}

function mc_upload {
  local EXPECTED_SIZE="$1"
  PATH_TO_BACKUP="minio_dest/${LOGICAL_BACKUP_S3_BUCKET}/${CLUSTER_NAME}/${LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX}/logical_backups/$(date +%s).sql.gz"

  setup_mc_alias

  echo "Uploading dump to MinIO: ${PATH_TO_BACKUP}"
  mc pipe "$PATH_TO_BACKUP"
}

function upload {
  case $LOGICAL_BACKUP_PROVIDER in
    "s3")
      mc_upload $(($(estimate_size) / DUMP_SIZE_COEFF))
      mc_delete_outdated
      ;;
    "az")
      # Azure requires a physical file for 'az storage blob upload' in this context
      dump | compress > /tmp/mariadb-backup.sql.gz
      generate_checksum /tmp/mariadb-backup.sql.gz
      az_upload /tmp/mariadb-backup.sql.gz
      rm /tmp/mariadb-backup.sql.gz
      ;;
  esac
}

if [ "$LOGICAL_BACKUP_PROVIDER" == "az" ]; then
  upload
else
  
  echo "Starting debug pipeline..."
  dump 2> /tmp/dump_stderr.log | tee /tmp/raw_dump.sql | compress > /tmp/final_upload.sql.gz
  
  PIPELINE_STATUS=("${PIPESTATUS[@]}")
  
  generate_checksum /tmp/final_upload.sql.gz
  cat /tmp/final_upload.sql.gz | upload
  UPLOAD_EXIT_CODE=$?    

  [[ ${PIPELINE_STATUS[0]} != 0 || ${PIPELINE_STATUS[1]} != 0 || ${PIPELINE_STATUS[2]} != 0 || ${UPLOAD_EXIT_CODE} != 0 ]] && (( ERRORCOUNT += 1 ))
  exit $ERRORCOUNT
fi