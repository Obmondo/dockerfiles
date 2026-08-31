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
#   BATCH_SIZE         versions per delete-objects call, max 1000 (default: 100).
#                      The API ceiling is 1000, but rustfs serialises per-object
#                      locks and returns "Lock acquisition timeout ... after 5s"
#                      for every key when handed a batch of a few hundred, so the
#                      default is set by what the server tolerates, not the API.
#   MAX_RETRIES        attempts per batch when the server reports lock contention
#                      or times out (default: 5)
#   RETRY_DELAY        seconds, multiplied by attempt number, between retries (default: 3)
#   CLI_READ_TIMEOUT   per-request read timeout passed to the AWS CLI (default: 120)
#   PAGE_SIZE          versions per list-object-versions request (default: 1000)
#   WORKDIR            scratch directory for batch files (default: ${TMPDIR:-/tmp})
set -eu

: "${ENDPOINT:?ENDPOINT is required}"
: "${BUCKETS:?BUCKETS is required (space-separated bucket names)}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"
: "${RETENTION_DAYS:=30}"
: "${EXCLUDE_PREFIXES:=}"
: "${BATCH_SIZE:=100}"
: "${PAGE_SIZE:=1000}"
: "${MAX_RETRIES:=5}"
: "${RETRY_DELAY:=3}"
: "${CLI_READ_TIMEOUT:=120}"
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

# Submits one prepared batch, retrying while the server reports lock contention.
# rustfs holds a per-object lock during delete and gives up after 5s, so a busy
# or large batch comes back with every key failed rather than a partial result.
# Those are transient and worth retrying; anything else is a real failure.
delete_batch() {
  batch_json=$1
  label=$2
  attempt=1
  while :; do
    if errors=$(aws s3api delete-objects --endpoint-url "$ENDPOINT" \
          --cli-read-timeout "$CLI_READ_TIMEOUT" \
          --cli-input-json "file://$batch_json" --query "Errors" --output text 2>"$SCRATCH/stderr"); then
      # Ask the CLI for the Errors key specifically. Quiet mode is meant to
      # return only errors, but not every S3 implementation honours it - rustfs
      # returns the full Deleted list - so treating "any output" as failure
      # reported a successful delete as an error.
      if [ -z "$errors" ] || [ "$errors" = "None" ]; then
        return 0
      fi
    fi
    detail="$errors $(cat "$SCRATCH/stderr" 2>/dev/null)"
    case "$detail" in
      *[Ll]ock*|*imeout*|*SlowDown*|*503*)
        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
          echo "retry $label: batch contended (attempt $attempt/$MAX_RETRIES)" >&2
          sleep $((RETRY_DELAY * attempt))
          attempt=$((attempt + 1))
          continue
        fi
        ;;
    esac
    echo "error $label: delete-objects failed after $attempt attempt(s)" >&2
    echo "$detail" | head -20 >&2
    exit 1
  done
}

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

    # DeleteObjects accepts at most 1000 entries per call, so split rather than
    # leaving the remainder to the next scheduled run - a prefix that grows
    # faster than one run removes would never converge.
    rm -rf "$SCRATCH/batches"
    mkdir -p "$SCRATCH/batches"
    split -l "$BATCH_SIZE" "$SCRATCH/versions" "$SCRATCH/batches/batch."

    for batch in "$SCRATCH"/batches/batch.*; do
      render_batch "$bucket" < "$batch" > "$batch.json"
      delete_batch "$batch.json" "$bucket/$prefix"
    done

    echo "clean $bucket/$prefix: permanently removed $count version(s)/marker(s) older than ${RETENTION_DAYS}d"
  done
done
