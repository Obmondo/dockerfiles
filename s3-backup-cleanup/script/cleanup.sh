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
# Deletes are issued one object at a time, CONCURRENCY in parallel, rather than
# in DeleteObjects batches. Batching is the obvious approach and is what this
# script used to do, but the only server it runs against is rustfs, whose bulk
# delete returns per-object "Lock acquisition timeout ... after 5s" for every
# key in a batch - reproducibly, on an idle server, for batches as small as two
# keys. Single deletes succeed. Batching also brought its own failures: the
# whole request body was once passed as a single argv entry and blew the 128 KiB
# MAX_ARG_STRLEN limit, and detecting failure in a batch response is server
# dependent (rustfs ignores the Quiet flag). None of that applies per object.
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
#   CONCURRENCY        parallel DeleteObject calls (default: 8)
#   PAGE_SIZE          versions per list-object-versions request (default: 1000)
#   MAX_RETRIES        attempts per object before the run fails (default: 5)
#   RETRY_DELAY        seconds, multiplied by attempt number, between retries (default: 3)
#   CLI_READ_TIMEOUT   per-request read timeout passed to the AWS CLI (default: 120)
#   WORKDIR            scratch directory (default: ${TMPDIR:-/tmp})
set -eu

: "${ENDPOINT:?ENDPOINT is required}"
: "${BUCKETS:?BUCKETS is required (space-separated bucket names)}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"
: "${RETENTION_DAYS:=30}"
: "${EXCLUDE_PREFIXES:=}"
: "${CONCURRENCY:=8}"
: "${PAGE_SIZE:=1000}"
: "${MAX_RETRIES:=5}"
: "${RETRY_DELAY:=3}"
: "${CLI_READ_TIMEOUT:=120}"
: "${WORKDIR:=${TMPDIR:-/tmp}}"

CUTOFF=$(date -u -d "-${RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)

SCRATCH=$(mktemp -d "${WORKDIR%/}/s3-backup-cleanup.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

echo "s3-backup-cleanup: endpoint=$ENDPOINT retention=${RETENTION_DAYS}d buckets=[$BUCKETS] exclude=[$EXCLUDE_PREFIXES]"

# Deletes one "Key<TAB>VersionId" line, retrying that object alone so a single
# contended key does not fail the whole run.
cat > "$SCRATCH/worker.sh" <<'WORKER'
#!/bin/sh
line=$1
key=${line%%	*}
vid=${line#*	}
[ -n "$key" ] && [ -n "$vid" ] || exit 0
n=1
while :; do
  if aws s3api delete-object --endpoint-url "$ENDPOINT" --bucket "$W_BUCKET" \
      --cli-read-timeout "$CLI_READ_TIMEOUT" \
      --key "$key" --version-id "$vid" >/dev/null 2>"$SCRATCH/err.$$"; then
    rm -f "$SCRATCH/err.$$"
    exit 0
  fi
  if [ "$n" -ge "$MAX_RETRIES" ]; then
    echo "  failed: $key ($vid): $(head -1 "$SCRATCH/err.$$" 2>/dev/null)" >&2
    rm -f "$SCRATCH/err.$$"
    exit 1
  fi
  sleep $((RETRY_DELAY * n))
  n=$((n + 1))
done
WORKER
chmod +x "$SCRATCH/worker.sh"

for bucket in $BUCKETS; do
  # Materialise the prefix listing rather than iterating the command substitution
  # directly: `for x in $(cmd)` discards the exit status, so an unreachable
  # endpoint produced an empty list and the script exited 0 having cleaned
  # nothing - reporting success for a total failure.
  if ! aws s3api list-objects-v2 --endpoint-url "$ENDPOINT" --bucket "$bucket" \
      --delimiter "/" --query "CommonPrefixes[].Prefix" --output text > "$SCRATCH/prefixes"; then
    echo "error $bucket: could not list prefixes" >&2
    exit 1
  fi

  for prefix in $(cat "$SCRATCH/prefixes"); do
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
    if ! aws s3api list-object-versions --endpoint-url "$ENDPOINT" --bucket "$bucket" --prefix "$prefix/" \
        --page-size "$PAGE_SIZE" \
        --query "[Versions[?LastModified<=\`$CUTOFF\`], DeleteMarkers[?LastModified<=\`$CUTOFF\`]][].[Key,VersionId]" \
        --output text > "$SCRATCH/raw"; then
      echo "error $bucket/$prefix: could not list object versions" >&2
      exit 1
    fi

    # Drop the "None" the CLI prints for an empty result, and any line the
    # query did not fill in completely.
    awk -F'\t' 'NF == 2 && $1 != "None" && $2 != "None"' "$SCRATCH/raw" > "$SCRATCH/versions"

    count=$(wc -l < "$SCRATCH/versions")
    if [ "$count" -eq 0 ]; then
      echo "clean $bucket/$prefix: nothing older than ${RETENTION_DAYS}d"
      continue
    fi

    W_BUCKET=$bucket
    export W_BUCKET ENDPOINT CLI_READ_TIMEOUT MAX_RETRIES RETRY_DELAY SCRATCH
    if ! xargs -P "$CONCURRENCY" -n 1 -d '\n' "$SCRATCH/worker.sh" < "$SCRATCH/versions"; then
      echo "error $bucket/$prefix: one or more deletes failed after $MAX_RETRIES attempt(s)" >&2
      exit 1
    fi

    echo "clean $bucket/$prefix: permanently removed $count version(s)/marker(s) older than ${RETENTION_DAYS}d"
  done
done
