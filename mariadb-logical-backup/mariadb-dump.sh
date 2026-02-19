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
  # command -v pigz >/dev/null 2>&1 && pigz || gzip

  # Use gzip explicitly to ensure compatibility
  gzip
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

function aws_delete_objects {
  args=("--bucket=$LOGICAL_BACKUP_S3_BUCKET")
  [[ -n "${LOGICAL_BACKUP_S3_ENDPOINT}" ]] && args+=("--endpoint-url=${LOGICAL_BACKUP_S3_ENDPOINT}")
  [[ -n "${LOGICAL_BACKUP_S3_REGION}" ]] && args+=("--region=${LOGICAL_BACKUP_S3_REGION}")

  aws s3api delete-objects "${args[@]}" --delete Objects=["$(printf \{Key=%q\}, "$@")"],Quiet=true
}
export -f aws_delete_objects

function aws_delete_outdated {
  if [[ -z "$LOGICAL_BACKUP_S3_RETENTION_TIME" ]] ; then
    echo "No retention time configured; skipping cleanup."
    return 0
  fi

  cutoff_date=$(date -d "$LOGICAL_BACKUP_S3_RETENTION_TIME ago" +%F)
  prefix="${CLUSTER_NAME}/${LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX}/logical_backups/"

  args=(
    "--no-paginate"
    "--output=text"
    "--prefix=$prefix"
    "--bucket=$LOGICAL_BACKUP_S3_BUCKET"
  )
  [[ -n "${LOGICAL_BACKUP_S3_ENDPOINT}" ]] && args+=("--endpoint-url=${LOGICAL_BACKUP_S3_ENDPOINT}")
  [[ -n "${LOGICAL_BACKUP_S3_REGION}" ]] && args+=("--region=${LOGICAL_BACKUP_S3_REGION}")

  aws s3api list-objects "${args[@]}" --query="Contents[?LastModified<='$cutoff_date'].[Key]" > /tmp/outdated-backups
  sed -i '$d' /tmp/outdated-backups # Spare the most recent backup

  count=$(wc -l < /tmp/outdated-backups)
  if [[ $count -gt 0 ]]; then
    echo "Deleting $count outdated backups created before $cutoff_date"
    tr '\n' '\0' < /tmp/outdated-backups | xargs -0 -P1 -n100 bash -c 'aws_delete_objects "$@"' _
  fi
}

function aws_upload {
  local FILE_PATH="$1"
  PATH_TO_BACKUP="s3://${LOGICAL_BACKUP_S3_BUCKET}/${CLUSTER_NAME}/${LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX}/logical_backups/$(date +%s).sql.gz"

  args=()
  [[ -n "${LOGICAL_BACKUP_S3_ENDPOINT}" ]] && args+=("--endpoint-url=${LOGICAL_BACKUP_S3_ENDPOINT}")
  [[ -n "${LOGICAL_BACKUP_S3_REGION}" ]] && args+=("--region=${LOGICAL_BACKUP_S3_REGION}")

  echo "Uploading dump to S3: ${PATH_TO_BACKUP}"
  aws s3 cp "${FILE_PATH}" "$PATH_TO_BACKUP" "${args[@]}"
}

function upload {
  local FILE_PATH="$1"
  case $LOGICAL_BACKUP_PROVIDER in
    "s3")
      aws_upload "$FILE_PATH"
      aws_delete_outdated
      ;;
    "az")
      az_upload "$FILE_PATH"
      ;;
  esac
}

# Execution Logic
if [ "$LOGICAL_BACKUP_PROVIDER" == "az" ]; then
  # Stream dump to a local file for debugging AND upload logic
  # Saving:
  # 1. /tmp/raw_dump.sql - The uncompressed output from mariadb-dump
  # 2. /tmp/dump_stderr.log - The verbose logs and errors from mariadb-dump
  # 3. /tmp/final_upload.sql.gz - The valid gzip file to be uploaded
  
  echo "Starting backup creation..."
  dump 2> /tmp/dump_stderr.log | tee /tmp/raw_dump.sql | compress > /tmp/final_upload.sql.gz
  
  # Capture status of the generation pipeline
  PIPELINE_STATUS=("${PIPESTATUS[@]}")
  echo "Backup generation finished with status: ${PIPELINE_STATUS[*]}"
  
  # Debug output
  echo "DEBUG FILES GENERATED:"
  echo "1. Stderr Log: /tmp/dump_stderr.log"
  echo "2. Raw Dump:   /tmp/raw_dump.sql"
  echo "3. Gzip File:  /tmp/final_upload.sql.gz"
  echo "Showing first 10 lines of raw dump:"
  head -n 10 /tmp/raw_dump.sql || echo "Empty file"

  if [[ ${PIPELINE_STATUS[0]} -ne 0 || ${PIPELINE_STATUS[1]} -ne 0 || ${PIPELINE_STATUS[2]} -ne 0 ]]; then
    echo "Backup generation failed! Skipping upload."
    ERRORCOUNT=$((ERRORCOUNT + 1))
  else
    echo "Backup generation successful. Proceeding to upload..."
    upload "/tmp/final_upload.sql.gz"
    
    if [ $? -ne 0 ]; then
       echo "Upload failed!"
       ERRORCOUNT=$((ERRORCOUNT + 1))
    fi
  fi
  
  echo "Sleeping for 1000s to allow manual debugging..."
  sleep 1000

  exit $ERRORCOUNT
fi