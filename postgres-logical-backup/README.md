# Postgres Logical Backup

A robust, containerized utility designed to automate logical backups of PostgreSQL databases and stream compressed archives directly to major cloud object storage providers (AWS S3 & S3-compatible endpoints, Google Cloud Storage, and Azure Blob Storage).

Designed with cloud-native workflows in mind, this tool integrates seamlessly with Kubernetes PostgreSQL operators—such as **Zalando's Postgres Operator / Spilo** and **CloudNativePG (CNPG)**—following standard operator backup structure and conventions.

---

## Features

- **Multi-Version PostgreSQL Client Support**: Bundles PostgreSQL client tools (`postgresql-client-10` through `postgresql-client-18`) sourced directly from the official PGDG repository.
- **High-Performance Compression**: Uses `pigz` (Parallel Implementation of Gzip) for fast, multi-threaded compression on the fly.
- **Multi-Cloud Storage Providers**:
  - **AWS S3** (and S3-compatible endpoints via custom URLs) with streaming uploads and expected size optimization.
  - **Google Cloud Storage (GCS)** via `gsutil`.
  - **Azure Blob Storage** via Azure CLI.
- **Flexible Backup Granularity**:
  - `pg_dumpall` (default): Dumps all databases cluster-wide (excluding the `postgres` database).
  - `pg_dump`: Targeted custom-format (`-Fc`) backup for a specific database when enabled.
- **Automated Retention Management**: Automatically lists, filters, and deletes outdated backups in S3 based on configurable retention policies while preserving the most recent backup.

---

## Environment Variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `PGHOST` | *Required* | PostgreSQL server hostname or IP address. |
| `PGPORT` | `5432` | PostgreSQL server port. |
| `PGUSER` | *Required* | PostgreSQL username for authentication. |
| `PGPASSWORD` | *Required* | PostgreSQL password for authentication. |
| `PGDATABASE` | `""` | Specific database name (required only if `USE_PG_DUMP=true`). |
| `PG_VERSION` | *Required* | PostgreSQL client version matching the server (e.g., `16`, `17`). Used to locate `pg_dump` / `psql`. |
| `USE_PG_DUMP` | `false` | When set to `true`, uses `pg_dump -Fc` for a single database (`PGDATABASE`) instead of `pg_dumpall`. |
| `POSTGRES_OPERATOR` | `spilo` | Operator namespace/prefix used in storage path structuring (`spilo`, `cnpg`, etc.). |
| `LOGICAL_BACKUP_PROVIDER` | `s3` | Cloud storage provider backend (`s3`, `gcs`, or `az`). |
| `LOGICAL_BACKUP_S3_BUCKET` | *Required* | Target bucket name for S3 / GCS, or container name for Azure. |
| `LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX` | `""` | Subpath or cluster identifier suffix matching operator path conventions. |
| `LOGICAL_BACKUP_S3_ENDPOINT` | `""` | Custom S3-compatible API endpoint URL (e.g., MinIO, LocalStack). |
| `LOGICAL_BACKUP_S3_REGION` | `""` | AWS region for the S3 bucket. |
| `LOGICAL_BACKUP_S3_RETENTION_TIME` | `""` | Retention duration for cleaning up old backups (e.g., `"7 days"`, `"1 month"`). Supported only for S3. |
| `LOGICAL_BACKUP_GOOGLE_APPLICATION_CREDENTIALS` | `""` | Path to the GCS service account JSON key file. |
| `LOGICAL_BACKUP_AZURE_STORAGE_ACCOUNT_NAME` | `""` | Azure Storage Account name. |
| `LOGICAL_BACKUP_AZURE_STORAGE_ACCOUNT_KEY` | `""` | Azure Storage Account access key. |
| `LOGICAL_BACKUP_AZURE_STORAGE_CONTAINER` | `""` | Azure Blob Storage container name. |

---

## Storage Path Conventions

When uploading backups, the tool organizes objects following operator path conventions:

- **AWS S3**: `s3://<BUCKET>/<POSTGRES_OPERATOR>/<SCOPE_SUFFIX>/logical_backups/<TIMESTAMP>.<sql.gz|dump.gz>`
- **Google Cloud Storage**: `gs://<BUCKET>/<POSTGRES_OPERATOR>/<SCOPE_SUFFIX>/logical_backups/<TIMESTAMP>.<sql.gz|dump.gz>`
- **Azure Blob**: `<BUCKET>/<POSTGRES_OPERATOR>/<SCOPE_SUFFIX>/logical_backups/<TIMESTAMP>.<sql.gz|dump.gz>`

---

## Releases & Pulling Pre-built Images

Images are automatically built and published via GitHub Actions to the **GitHub Container Registry (GHCR)** on pushes to `main` and scheduled workflows.

- **Registry Image**: `ghcr.io/obmondo/postgres-logical-backup`
- **Supported Architectures**: `linux/amd64`, `linux/arm64`
- **Tags**:
  - `latest`: Points to the latest build on `main`.
  - Date-based version tags (e.g., `YY.M.0`).

### Pulling and Testing Locally

You can pull and run the pre-built image directly from GHCR:

```bash
docker pull ghcr.io/obmondo/postgres-logical-backup:latest

docker run --rm \
  -e PGHOST="postgres.local" \
  -e PGUSER="postgres" \
  -e PGPASSWORD="secretpassword" \
  -e PG_VERSION="16" \
  -e POSTGRES_OPERATOR="cnpg" \
  -e LOGICAL_BACKUP_PROVIDER="s3" \
  -e LOGICAL_BACKUP_S3_BUCKET="my-backup-bucket" \
  -e LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX="/my-cluster" \
  -e AWS_ACCESS_KEY_ID="your_access_key" \
  -e AWS_SECRET_ACCESS_KEY="your_secret_key" \
  ghcr.io/obmondo/postgres-logical-backup:latest
```

---

## Usage Examples

### 1. Build the Docker Image Locally

```bash
docker build -t postgres-logical-backup .
```

### 2. Run AWS S3 Backup (Cluster-wide `pg_dumpall`)

```bash
docker run --rm \
  -e PGHOST="postgres.local" \
  -e PGUSER="postgres" \
  -e PGPASSWORD="secretpassword" \
  -e PG_VERSION="16" \
  -e LOGICAL_BACKUP_PROVIDER="s3" \
  -e LOGICAL_BACKUP_S3_BUCKET="my-backup-bucket" \
  -e LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX="/my-cluster" \
  -e LOGICAL_BACKUP_S3_REGION="us-east-1" \
  -e LOGICAL_BACKUP_S3_RETENTION_TIME="14 days" \
  -e AWS_ACCESS_KEY_ID="your_access_key" \
  -e AWS_SECRET_ACCESS_KEY="your_secret_key" \
  postgres-logical-backup
```

### 3. Run Single Database Backup (`pg_dump -Fc`) with MinIO / S3-Compatible Endpoint

```bash
docker run --rm \
  -e PGHOST="postgres.local" \
  -e PGUSER="postgres" \
  -e PGPASSWORD="secretpassword" \
  -e PGDATABASE="app_production" \
  -e PG_VERSION="15" \
  -e USE_PG_DUMP="true" \
  -e LOGICAL_BACKUP_PROVIDER="s3" \
  -e LOGICAL_BACKUP_S3_BUCKET="backups" \
  -e LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX="/cluster-prod" \
  -e LOGICAL_BACKUP_S3_ENDPOINT="http://minio.local:9000" \
  -e AWS_ACCESS_KEY_ID="minioadmin" \
  -e AWS_SECRET_ACCESS_KEY="minioadmin" \
  postgres-logical-backup
```

### 4. Run Google Cloud Storage (GCS) Backup

```bash
docker run --rm \
  -e PGHOST="postgres.local" \
  -e PGUSER="postgres" \
  -e PGPASSWORD="secretpassword" \
  -e PG_VERSION="16" \
  -e LOGICAL_BACKUP_PROVIDER="gcs" \
  -e LOGICAL_BACKUP_S3_BUCKET="my-gcs-bucket" \
  -e LOGICAL_BACKUP_S3_BUCKET_SCOPE_SUFFIX="/my-cluster" \
  -e LOGICAL_BACKUP_GOOGLE_APPLICATION_CREDENTIALS="/etc/secrets/gcs-key.json" \
  -v /path/to/gcs-key.json:/etc/secrets/gcs-key.json:ro \
  postgres-logical-backup
```

---

## References & Upstream Projects

- [Zalando Postgres Operator](https://github.com/zalando/postgres-operator)
- [CloudNativePG (CNPG)](https://cloudnative-pg.io/)
- [Spilo (PostgreSQL HA Appliance)](https://github.com/zalando/spilo)
- [PostgreSQL Global Development Group (PGDG) Apt Repository](https://apt.postgresql.org/)
- [AWS CLI v2](https://aws.amazon.com/cli/)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/)
- [Google Cloud SDK / gsutil](https://docs.cloud.google.com/storage/docs/gsutil)
