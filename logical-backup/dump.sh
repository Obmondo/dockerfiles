#! /usr/bin/env bash
set +x

PG_BIN=$PG_DIR/$PG_VERSION/bin

export PG_HOST="output-etl-db.modeling.svc.cluster.local"
export PG_PORT="5432"

pg_dumpall | pigz /tmp/logicalbakup.sql.gz

aws s3 cp s3://bw7-k8s-production-postgres-backup/spilo/output-etl-db/"$LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX"/

