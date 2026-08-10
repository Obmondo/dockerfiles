#!/bin/sh
# Permanently prunes objects older than RETENTION_DAYS from the top-level prefixes
# of one or more S3-compatible buckets, skipping any prefix in EXCLUDE_PREFIXES.
#
# On a versioned bucket, a plain DeleteObject call does not free space - it only
# adds a delete marker and leaves the underlying version on disk. So instead of
# deleting by key, every matched Version and DeleteMarker is looked up via
# list-object-versions and deleted by its specific VersionId, which permanently
# removes it whether or not the bucket has versioning enabled.
#
# Required env vars:
#   ENDPOINT           S3-compatible endpoint URL, e.g. http://rustfs-svc.rustfs.svc.cluster.local:9000
#   BUCKETS            space-separated bucket names to clean
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   credentials (standard AWS CLI env vars)
#
# Optional env vars:
#   RETENTION_DAYS     objects older than this many days are deleted (default: 30)
#   EXCLUDE_PREFIXES   space-separated top-level prefixes to skip (default: none)
#   AWS_DEFAULT_REGION region passed to the AWS CLI (default: us-east-1)
set -eu

: "${ENDPOINT:?ENDPOINT is required}"
: "${BUCKETS:?BUCKETS is required (space-separated bucket names)}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"
: "${RETENTION_DAYS:=30}"
: "${EXCLUDE_PREFIXES:=}"

CUTOFF=$(date -u -d "-${RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)

echo "s3-backup-cleanup: endpoint=$ENDPOINT retention=${RETENTION_DAYS}d buckets=[$BUCKETS] exclude=[$EXCLUDE_PREFIXES]"

# delete-objects accepts at most 1000 entries per call. A single prefix
# accumulating more stale versions than that between runs is not expected;
# any remainder is picked up by the next scheduled run.
for bucket in $BUCKETS; do
  for prefix in $(aws s3api list-objects-v2 --endpoint-url "$ENDPOINT" --bucket "$bucket" --delimiter "/" --query "CommonPrefixes[].Prefix" --output text); do
    prefix=${prefix%/}
    skip=0
    for ex in $EXCLUDE_PREFIXES; do
      [ "$prefix" = "$ex" ] && skip=1
    done
    if [ "$skip" -eq 1 ]; then
      echo "skip  $bucket/$prefix (excluded)"
      continue
    fi

    count=$(aws s3api list-object-versions --endpoint-url "$ENDPOINT" --bucket "$bucket" --prefix "$prefix/" \
      --query "length([Versions[?LastModified<=\`$CUTOFF\`], DeleteMarkers[?LastModified<=\`$CUTOFF\`]][])" --output text)
    if [ "$count" = "0" ]; then
      echo "clean $bucket/$prefix: nothing older than ${RETENTION_DAYS}d"
      continue
    fi

    payload=$(aws s3api list-object-versions --endpoint-url "$ENDPOINT" --bucket "$bucket" --prefix "$prefix/" \
      --query "{Objects: [Versions[?LastModified<=\`$CUTOFF\`], DeleteMarkers[?LastModified<=\`$CUTOFF\`]][].{Key:Key,VersionId:VersionId}}" --output json)
    aws s3api delete-objects --endpoint-url "$ENDPOINT" --bucket "$bucket" --delete "$payload" >/dev/null
    echo "clean $bucket/$prefix: permanently removed $count version(s)/marker(s) older than ${RETENTION_DAYS}d"
  done
done
