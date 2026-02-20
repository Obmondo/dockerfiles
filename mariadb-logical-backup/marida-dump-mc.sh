#! /usr/bin/env bash

set -x
set -eou pipefail
IFS=$'\n\t'

## Required Env passed from CronJob:
# MARIADB_HOST, MARIADB_USER, MARIADB_PASSWORD, MARIADB_DATABASE (or use .my.cnf)
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (needed for mc alias setup)
# LOGICAL_BACKUP_PROVIDER, LOGICAL_BACKUP_S3_BUCKET, etc.

# MariaDB query to get total size of all databases in bytes
ALL_DB_SIZE_QUERY="SELECT SUM(data_length + index_length) FROM information_schema.TABLES;"
DUMP_SIZE_COEFF=5
ERRORCOUNT=0
CLUSTER_NAME=${CLUSTER_NAME_LABEL:-"mariadb-cluster"}
LOGICAL_BACKUP_PROVIDER=${LOGICAL_BACKUP_PROVIDER:="s3"}
LOGICAL_BACKUP_S3_RETENTION_TIME=${LOGICAL_BACKUP_S3_RETENTION_TIME:=""} # e.g. "7d" or "30d" for mc
LOGICAL_BACKUP_S3_ENDPOINT=${LOGICAL_BACKUP_S3_ENDPOINT:-"https://s3.amazonaws.com"}
LOGICAL_BACKUP_S3_REGION=${LOGICAL_BACKUP_S3_REGION:-"us-west-1"}

function estimate_size {
  # Connects to MariaDB to calculate data size (kept for compatibility/logging if needed)
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
  # Use gzip explicitly to ensure compatibility
  gzip
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

function mc_setup {
  echo "Configuring mc client..."
  # Sets up a temporary alias named 'backup_target' using the standard AWS credential vars
  mc alias set backup_target "${LOGICAL_BACKUP_S3_ENDPOINT}" "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}"
}

function mc_delete_outdated {
  if [[ -z "$LOGICAL_BACKUP_S3_RETENTION_TIME" ]] ; then
    echo "No retention time configured; skipping cleanup."
    return 0
  fi

  # NOTE: With mc, LOGICAL_BACKUP_S3_RETENTION_TIME should be formatted as a duration like "7d" or "30d"
  prefix="backup_target/${LOGICAL_BACKUP_S3_BUCKET}/${CLUSTER_NAME}/${LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX}/logical_backups/"

  echo "Deleting backups older than ${LOGICAL_BACKUP_S3_RETENTION_TIME}..."
  mc rm --recursive --force --older-than "${LOGICAL_BACKUP_S3_RETENTION_TIME}" "$prefix"
}

function mc_upload {
  PATH_TO_BACKUP="backup_target/${LOGICAL_BACKUP_S3_BUCKET}/${CLUSTER_NAME}/${LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX}/logical_backups/$(date +%s).sql.gz"

  echo "Uploading dump to S3 via mc: ${PATH_TO_BACKUP}"
  # 'mc pipe' takes stdin and streams it directly to the target object
  mc pipe "$PATH_TO_BACKUP"
}

function upload {
  case $LOGICAL_BACKUP_PROVIDER in
    "s3")
      mc_setup
      mc_upload
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

# Execution Logic
if [ "$LOGICAL_BACKUP_PROVIDER" == "az" ]; then
  upload
else
  # Stream dump to a local file for debugging AND upload to S3
  # Saving:
  # 1. /tmp/raw_dump.sql - The uncompressed output from mariadb-dump (Check this for plain text errors)
  # 2. /tmp/dump_stderr.log - The verbose logs and errors from mariadb-dump
  # 3. /tmp/final_upload.sql.gz - The valid gzip file sent to S3
  
  echo "Starting debug pipeline..."
  dump 2> /tmp/dump_stderr.log | tee /tmp/raw_dump.sql | compress > /tmp/final_upload.sql.gz
  
  # Capture status immediately!
  PIPELINE_STATUS=("${PIPESTATUS[@]}")
  
  generate_checksum /tmp/final_upload.sql.gz

  cat /tmp/final_upload.sql.gz | upload
  UPLOAD_EXIT_CODE=$?
  
  echo "Backup finished with status: ${PIPELINE_STATUS[*]} Upload: ${UPLOAD_EXIT_CODE}"
  echo "DEBUG FILES GENERATED:"
  echo "1. Stderr Log: /tmp/dump_stderr.log"
  echo "2. Raw Dump:   /tmp/raw_dump.sql"
  echo "3. Gzip File:  /tmp/final_upload.sql.gz"
  
  echo "Showing first 10 lines of raw dump (to check if it's SQL or error text):"
  head -n 10 /tmp/raw_dump.sql || echo "Empty file"
  
  echo "Sleeping for 500s to allow manual debugging..."
  sleep 500
  

  [[ ${PIPELINE_STATUS[0]} != 0 || ${PIPELINE_STATUS[1]} != 0 || ${PIPELINE_STATUS[2]} != 0 || ${UPLOAD_EXIT_CODE} != 0 ]] && (( ERRORCOUNT += 1 ))
  exit $ERRORCOUNT
fi