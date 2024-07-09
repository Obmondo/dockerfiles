#! /usr/bin/env bash
set +x

PG_BIN=$PG_DIR/$PG_VERSION/bin

export PGHOST="output-etl-db.modeling.svc.cluster.local"
export PGPORT="5432"

pg_dumpall > /backup/backup.sql

aws s3 cp /backup/backup.sql s3://bw7-k8s-production-postgres-backup/spilo/output-etl-db/"$LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX"/

