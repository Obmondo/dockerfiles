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
#   KEEP_ONLY_LATEST_PREFIXES        prefixes where only the latest version of each
#                                    object is kept and older ones are deleted. Live
#                                    objects always survive, so this is safe for a
#                                    prefix that must keep its contents, such as a
#                                    Velero/kopia repository (default: none)
#   KEEP_ONLY_LATEST_RETENTION_DAYS  age threshold for it (default: RETENTION_DAYS)
#   KEEP_ONLY_LATEST_BATCH_SIZE      versions per delete-objects call there (default:
#                                    200; rustfs read-times-out on 1000 for a large
#                                    prefix)
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
: "${KEEP_ONLY_LATEST_PREFIXES:=}"
: "${KEEP_ONLY_LATEST_RETENTION_DAYS:=$RETENTION_DAYS}"
: "${KEEP_ONLY_LATEST_BATCH_SIZE:=200}"
: "${BATCH_SIZE:=1000}"
: "${PAGE_SIZE:=1000}"
: "${WORKDIR:=${TMPDIR:-/tmp}}"

CUTOFF=$(date -u -d "-${RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
KEEP_ONLY_LATEST_CUTOFF=$(date -u -d "-${KEEP_ONLY_LATEST_RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)

SCRATCH=$(mktemp -d "${WORKDIR%/}/s3-backup-cleanup.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

echo "s3-backup-cleanup: endpoint=$ENDPOINT retention=${RETENTION_DAYS}d buckets=[$BUCKETS] exclude=[$EXCLUDE_PREFIXES] keep_only_latest=[$KEEP_ONLY_LATEST_PREFIXES] keep_only_latest_retention=${KEEP_ONLY_LATEST_RETENTION_DAYS}d"

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

# Lists the narrowest prefixes worth walking under $2, one or two levels down.
#
# A list or delete scoped to a whole Velero/kopia prefix makes rustfs time out its
# internal metacache walk ("Metacache listing quorum failed ... drive /data returned:
# timeout") and then answer DeleteObjects with ServiceUnavailable for most entries -
# measured here at 144 failures per 200 keys, 50s per call. The identical calls scoped
# to one subprefix finish in about a second with no errors, so walk the subprefixes
# rather than the parent.
# Sends one DeleteObjects request built from TAB-separated "Key<TAB>VersionId" lines.
# rustfs ignores Quiet and returns the full Deleted list, so "any output" is not a
# failure signal - ask for the Errors key. No read timeout: the call can take minutes
# and the CLI default aborts the run half way through.
delete_versions() {
  bucket=$1
  file=$2
  context=$3

  render_batch "$bucket" < "$file" > "$file.json"
  errors=$(aws s3api delete-objects --endpoint-url "$ENDPOINT" --cli-read-timeout 0 \
    --cli-input-json "file://$file.json" --query "Errors" --output text)
  if [ -n "$errors" ] && [ "$errors" != "None" ]; then
    echo "error $context: delete-objects reported failures" >&2
    echo "$errors" >&2
    exit 1
  fi
}

# Emits every prefix under $2, itself included, one per line.
#
# Each is then listed with a delimiter so only its direct keys are touched. A list or
# delete scoped to a whole kopia repository makes rustfs time out its metacache walk
# ("drive /data returned: timeout") and answer DeleteObjects with ServiceUnavailable
# for most entries - 144 of 200 keys, 50s per call - while the same calls scoped to a
# single level finish in about a second.
walk_prefixes() {
  bucket=$1
  root=$2

  echo "$root"
  for child in $(aws s3api list-objects-v2 --endpoint-url "$ENDPOINT" --bucket "$bucket" \
    --prefix "$root" --delimiter "/" --no-paginate \
    --query "CommonPrefixes[].Prefix" --output text 2>/dev/null | tr '\t' '\n'); do
    [ -n "$child" ] && [ "$child" != "None" ] || continue
    walk_prefixes "$bucket" "$child"
  done
}

# Deletes the superseded versions held directly under one prefix level.
prune_level() {
  bucket=$1
  level=$2
  deleted=0

  while : ; do
    if ! aws s3api list-object-versions --endpoint-url "$ENDPOINT" --bucket "$bucket" \
      --prefix "$level" --delimiter "/" --max-keys "$KEEP_ONLY_LATEST_BATCH_SIZE" --no-paginate \
      --query "[Versions[?IsLatest==\`false\` && LastModified<=\`$KEEP_ONLY_LATEST_CUTOFF\`], DeleteMarkers[?IsLatest==\`false\` && LastModified<=\`$KEEP_ONLY_LATEST_CUTOFF\`]][].[Key,VersionId]" \
      --output text > "$SCRATCH/raw" 2>/dev/null; then
      echo "error $bucket/$level: could not list old versions" >&2
      exit 1
    fi

    awk -F'\t' 'NF == 2 && $1 != "None" && $2 != "None"' "$SCRATCH/raw" > "$SCRATCH/versions"
    count=$(wc -l < "$SCRATCH/versions")
    [ "$count" -eq 0 ] && break

    delete_versions "$bucket" "$SCRATCH/versions" "$bucket/$level"
    deleted=$((deleted + count))
  done

  echo "$deleted"
}

# Keeps only the latest version of each object: deletes every older version, plus
# delete markers that are not the latest. Live objects survive untouched.
#
# kopia compacts its indexes and deletes superseded blobs, but on a versioned bucket a
# delete only writes a marker and keeps the old version, and kopia has no notion of S3
# versioning - 231G on disk against 176G of current objects here, one kopia.maintenance
# key holding 839 versions. A latest delete marker is kept: removing it would un-delete
# the object.
prune_old_versions() {
  bucket=$1
  prefix=$2
  total=0

  walk_prefixes "$bucket" "$prefix/" > "$SCRATCH/levels"
  while IFS= read -r level; do
    [ -n "$level" ] || continue
    total=$((total + $(prune_level "$bucket" "$level")))
  done < "$SCRATCH/levels"

  if [ "$total" -eq 0 ]; then
    echo "clean $bucket/$prefix: no superseded version older than ${KEEP_ONLY_LATEST_RETENTION_DAYS}d"
    return
  fi

  echo "clean $bucket/$prefix: permanently removed $total superseded version(s)/marker(s) older than ${KEEP_ONLY_LATEST_RETENTION_DAYS}d (latest version of each object kept)"
}

for bucket in $BUCKETS; do
  # `for x in $(cmd)` discards the exit status, so an unreachable endpoint gave
  # an empty list and the script exited 0 having cleaned nothing.
  if ! aws s3api list-objects-v2 --endpoint-url "$ENDPOINT" --bucket "$bucket" \
      --delimiter "/" --query "CommonPrefixes[].Prefix" --output text > "$SCRATCH/prefixes"; then
    echo "error $bucket: could not list prefixes" >&2
    exit 1
  fi

  for prefix in $(cat "$SCRATCH/prefixes"); do
    prefix=${prefix%/}

    # This wins over EXCLUDE_PREFIXES: a prefix is normally excluded because deleting
    # its current versions would destroy live backups, which is exactly the case
    # keeping only the latest version is safe for.
    keep_latest=0
    for kl in $KEEP_ONLY_LATEST_PREFIXES; do
      [ "$prefix" = "$kl" ] && keep_latest=1
    done
    if [ "$keep_latest" -eq 1 ]; then
      prune_old_versions "$bucket" "$prefix"
      continue
    fi

    skip=0
    for ex in $EXCLUDE_PREFIXES; do
      [ "$prefix" = "$ex" ] && skip=1
    done
    if [ "$skip" -eq 1 ]; then
      echo "skip  $bucket/$prefix (excluded)"
      continue
    fi

    # ListObjectVersions cannot be trusted for enumeration: rustfs caps the reply
    # at 100 entries, ignores --max-keys, and returns neither IsTruncated nor
    # NextKeyMarker, so a client cannot tell the list was cut short nor page past
    # it. Filtering that silent subset by age found nothing old and the run
    # reported success while 482 expired objects stayed on disk.
    #
    # ListObjectsV2 paginates correctly, so enumerate the expired keys with it and
    # look the versions up one key at a time, where the per-key count is far below
    # the cap.
    if ! aws s3api list-objects-v2 --endpoint-url "$ENDPOINT" --bucket "$bucket" --prefix "$prefix/" \
      --page-size "$PAGE_SIZE" \
      --query "Contents[?LastModified<=\`$CUTOFF\`].[Key]" \
      --output text > "$SCRATCH/keys"; then
      echo "error $bucket/$prefix: could not list objects" >&2
      exit 1
    fi

    : > "$SCRATCH/raw"
    while IFS= read -r key; do
      [ -n "$key" ] && [ "$key" != "None" ] || continue
      if ! aws s3api list-object-versions --endpoint-url "$ENDPOINT" --bucket "$bucket" --prefix "$key" \
        --query "[Versions[?Key=='$key'], DeleteMarkers[?Key=='$key']][].[Key,VersionId]" \
        --output text >> "$SCRATCH/raw"; then
        echo "error $bucket/$prefix: could not list versions of $key" >&2
        exit 1
      fi
    done < "$SCRATCH/keys"

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
      delete_versions "$bucket" "$batch" "$bucket/$prefix"
    done

    # Confirm the deletes actually took effect. Without this the run can report
    # success while the objects are still there, which is how this job appeared
    # healthy for weeks while nothing was pruned.
    if ! remaining=$(aws s3api list-objects-v2 --endpoint-url "$ENDPOINT" --bucket "$bucket" --prefix "$prefix/" \
      --page-size "$PAGE_SIZE" \
      --query "length(Contents[?LastModified<=\`$CUTOFF\`])" --output text); then
      echo "error $bucket/$prefix: could not verify deletion" >&2
      exit 1
    fi
    [ "$remaining" = "None" ] && remaining=0
    if [ "$remaining" -ne 0 ]; then
      echo "error $bucket/$prefix: $remaining object(s) older than ${RETENTION_DAYS}d still present after deleting $count version(s)" >&2
      exit 1
    fi

    echo "clean $bucket/$prefix: permanently removed $count version(s)/marker(s) older than ${RETENTION_DAYS}d"
  done
done
