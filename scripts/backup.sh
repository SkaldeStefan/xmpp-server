#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
DEFAULT_PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROJECT_DIR="${PROJECT_DIR:-$DEFAULT_PROJECT_DIR}"
COMPOSE_FILE="${COMPOSE_FILE:-$PROJECT_DIR/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups}"

usage() {
  cat <<'EOF'
Usage: scripts/backup.sh [--keep-days DAYS] [--backup-dir PATH]

Environment overrides:
  PROJECT_DIR, COMPOSE_FILE, ENV_FILE, SECRETS_DIR, BACKUP_DIR, RETENTION_DAYS,
  BACKUP_RETENTION_DAYS, POSTGRES_DB, POSTGRES_USER
EOF
}

wait_for_postgres() {
  local tries=30
  local i
  for ((i = 1; i <= tries; i++)); do
    if compose_cmd exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: postgres is not ready after $tries attempts." >&2
  return 1
}

require_positive_int() {
  local label="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*)
      echo "ERROR: $label must be a positive integer." >&2
      return 1
      ;;
    *)
      if [ "$value" -le 0 ]; then
        echo "ERROR: $label must be greater than zero." >&2
        return 1
      fi
      ;;
  esac
}

check_secret_file() {
  local secret_file="$1"
  if [ ! -s "$secret_file" ]; then
    echo "ERROR: required secret file missing or empty: $secret_file" >&2
    return 1
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep-days)
        [ "$#" -ge 2 ] || { echo "ERROR: --keep-days requires a value." >&2; exit 1; }
        RETENTION_DAYS="$2"
        shift 2
        ;;
      --backup-dir)
        [ "$#" -ge 2 ] || { echo "ERROR: --backup-dir requires a path." >&2; exit 1; }
        BACKUP_DIR="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: unknown argument '$1'" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

main() {
  local timestamp backup_basename backup_path
  local tmp_dir
  local files_archive_path
  local file

  maybe_reexec_with_sudo_if_env_unreadable "PROJECT_DIR,COMPOSE_FILE,ENV_FILE,SECRETS_DIR,BACKUP_DIR,RETENTION_DAYS,BACKUP_RETENTION_DAYS,POSTGRES_DB,POSTGRES_USER" "$@"
  parse_args "$@"

  load_env_file "$ENV_FILE" env_key_is_set

  POSTGRES_DB="${POSTGRES_DB:-prosody}"
  POSTGRES_USER="${POSTGRES_USER:-prosody}"
  RETENTION_DAYS="${RETENTION_DAYS:-${BACKUP_RETENTION_DAYS:-14}}"
  SECRETS_DIR="${SECRETS_DIR:-$PROJECT_DIR/secrets}"
  BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups}"
  require_positive_int "RETENTION_DAYS" "$RETENTION_DAYS"

  check_secret_file "$SECRETS_DIR/postgres_password.txt"

  if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: compose file not found: $COMPOSE_FILE" >&2
    exit 1
  fi

  mkdir -p "$BACKUP_DIR"

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_basename="xmpp-backup-${timestamp}.tar.gz"
  backup_path="$BACKUP_DIR/$backup_basename"

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  compose_cmd up -d postgres >/dev/null
  wait_for_postgres

  echo "Creating PostgreSQL dump..."
  compose_cmd exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$tmp_dir/postgres.dump"

  files_archive_path="$tmp_dir/prosody-files.tar.gz"
  : > "$tmp_dir/include-list.txt"
  for file in docker-compose.yml .env prosody-config prosody-data prosody-certs; do
    if [ -e "$PROJECT_DIR/$file" ]; then
      printf '%s\n' "$file" >> "$tmp_dir/include-list.txt"
    fi
  done

  echo "Archiving project files..."
  tar -C "$PROJECT_DIR" -czf "$files_archive_path" -T "$tmp_dir/include-list.txt"

  cat > "$tmp_dir/metadata.env" <<EOF
CREATED_AT_UTC=$timestamp
POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
SOURCE_PROJECT_DIR=$PROJECT_DIR
EOF

  tar -C "$tmp_dir" -czf "$backup_path" postgres.dump prosody-files.tar.gz metadata.env
  chmod 600 "$backup_path"

  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'xmpp-backup-*.tar.gz' -mtime "+$RETENTION_DAYS" -delete

  echo "Backup written: $backup_path"
}

main "$@"
