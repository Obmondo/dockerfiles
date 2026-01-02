#! /usr/bin/env bash

set -eou pipefail
IFS=$'\n\t'

## Required Env passed from CronJob:
# MARIADB_HOST, MARIADB_USER, MARIADB_PASSWORD (or use .my.cnf)
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
    --skip-ssl -Nsr -e "${ALL_DB_SIZE_QUERY}"
}

function dump {
  echo "Taking dump from ${MARIADB_HOST} using mariadb-dump"
  
  # --all-databases: Backup everything
  # --single-transaction: Ensure consistency for InnoDB without locking
  # --quick: Stream output to save memory
  # --routines: Include stored procedures
  mariadb-dump -h "$MARIADB_HOST" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -P "$MARIADB_PORT" \
    --all-databases \
    --system=users \
    --single-transaction \
    --quick \
    --routines \
    --events \
    --skip-ssl \
    --insert-ignore \
    --verbose
}

function compress {
  # Use pigz for multi-threaded compression if available, else gzip
  command -v pigz >/dev/null 2>&1 && pigz || gzip
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
  local EXPECTED_SIZE="$1"
  PATH_TO_BACKUP="s3://${LOGICAL_BACKUP_S3_BUCKET}/${CLUSTER_NAME}/${LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX}/logical_backups/$(date +%s).sql.gz"

  args=()
  [[ -n "${EXPECTED_SIZE}" ]] && args+=("--expected-size=${EXPECTED_SIZE}")
  [[ -n "${LOGICAL_BACKUP_S3_ENDPOINT}" ]] && args+=("--endpoint-url=${LOGICAL_BACKUP_S3_ENDPOINT}")
  [[ -n "${LOGICAL_BACKUP_S3_REGION}" ]] && args+=("--region=${LOGICAL_BACKUP_S3_REGION}")

  echo "Uploading dump to S3: ${PATH_TO_BACKUP}"
  echo "${args[@]}"
  aws s3 cp - "$PATH_TO_BACKUP" "${args[@]}"
}

function upload {
  case $LOGICAL_BACKUP_PROVIDER in
    "s3")
      aws_upload $(($(estimate_size) / DUMP_SIZE_COEFF))
      aws_delete_outdated
      ;;
    "az")
      # Azure requires a physical file for 'az storage blob upload' in this context
      dump | compress > /tmp/mariadb-backup.sql.gz
      az_upload /tmp/mariadb-backup.sql.gz
      rm /tmp/mariadb-backup.sql.gz
      ;;
  esac
}

# Execution Logic
if [ "$LOGICAL_BACKUP_PROVIDER" == "az" ]; then
  upload
else
  # Stream dump directly to S3 to save disk space
  dump | compress | upload
  [[ ${PIPESTATUS[0]} != 0 || ${PIPESTATUS[1]} != 0 || ${PIPESTATUS[2]} != 0 ]] && (( ERRORCOUNT += 1 ))
  exit $ERRORCOUNT
fi
