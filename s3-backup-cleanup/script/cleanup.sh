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
#   BATCH_SIZE         versions per delete-objects call, max 1000 (default: 1000)
#   PAGE_SIZE          versions per list-object-versions request (default: 1000)
#   WORKDIR            scratch directory for batch files (default: ${TMPDIR:-/tmp})
set -eu

: "${ENDPOINT:?ENDPOINT is required}"
: "${BUCKETS:?BUCKETS is required (space-separated bucket names)}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"
: "${RETENTION_DAYS:=30}"
: "${EXCLUDE_PREFIXES:=}"
: "${BATCH_SIZE:=1000}"
: "${PAGE_SIZE:=1000}"
: "${WORKDIR:=${TMPDIR:-/tmp}}"

CUTOFF=$(date -u -d "-${RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)

SCRATCH=$(mktemp -d "${WORKDIR%/}/s3-backup-cleanup.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

echo "s3-backup-cleanup: endpoint=$ENDPOINT retention=${RETENTION_DAYS}d buckets=[$BUCKETS] exclude=[$EXCLUDE_PREFIXES]"

# Renders TAB-separated "Key<TAB>VersionId" lines as a DeleteObjects request
# body. Passing the request as a file keeps it off the argument vector: a prefix
# with a few thousand stale versions produces well over the 128 KiB the kernel
# allows for a single argv entry (MAX_ARG_STRLEN), which is why building the
# payload inline used to abort the run with "Argument list too long".
render_batch() {
  awk -F'\t' -v bucket="$1" '
    function json(s) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      return s
    }
    BEGIN { printf "{\"Bucket\":\"%s\",\"Delete\":{\"Quiet\":true,\"Objects\":[", json(bucket) }
    { printf "%s{\"Key\":\"%s\",\"VersionId\":\"%s\"}", (NR > 1 ? "," : ""), json($1), json($2) }
    END { print "]}}" }
  '
}

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

    # --page-size bounds each ListObjectVersions request; the CLI still walks
    # every page. Without it the server is asked for the whole prefix in one
    # response, which some S3 implementations answer too slowly to complete.
    aws s3api list-object-versions --endpoint-url "$ENDPOINT" --bucket "$bucket" --prefix "$prefix/" \
      --page-size "$PAGE_SIZE" \
      --query "[Versions[?LastModified<=\`$CUTOFF\`], DeleteMarkers[?LastModified<=\`$CUTOFF\`]][].[Key,VersionId]" \
      --output text > "$SCRATCH/raw"

    # Drop the "None" the CLI prints for an empty result, and any line the
    # query did not fill in completely.
    awk -F'\t' 'NF == 2 && $1 != "None" && $2 != "None"' "$SCRATCH/raw" > "$SCRATCH/versions"

    count=$(wc -l < "$SCRATCH/versions")
    if [ "$count" -eq 0 ]; then
      echo "clean $bucket/$prefix: nothing older than ${RETENTION_DAYS}d"
      continue
    fi

    # DeleteObjects accepts at most 1000 entries per call, so split rather than
    # leaving the remainder to the next scheduled run - a prefix that grows
    # faster than one run removes would never converge.
    rm -rf "$SCRATCH/batches"
    mkdir -p "$SCRATCH/batches"
    split -l "$BATCH_SIZE" "$SCRATCH/versions" "$SCRATCH/batches/batch."

    for batch in "$SCRATCH"/batches/batch.*; do
      render_batch "$bucket" < "$batch" > "$batch.json"
      errors=$(aws s3api delete-objects --endpoint-url "$ENDPOINT" --cli-input-json "file://$batch.json")
      # Quiet mode returns nothing on success and an Errors array otherwise.
      if [ -n "$errors" ]; then
        echo "error $bucket/$prefix: delete-objects reported failures" >&2
        echo "$errors" >&2
        exit 1
      fi
    done

    echo "clean $bucket/$prefix: permanently removed $count version(s)/marker(s) older than ${RETENTION_DAYS}d"
  done
done
