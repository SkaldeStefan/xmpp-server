#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
DEFAULT_PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROJECT_DIR="${PROJECT_DIR:-$DEFAULT_PROJECT_DIR}"
COMPOSE_FILE="${COMPOSE_FILE:-$PROJECT_DIR/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
FORCE_RESTORE=0
BACKUP_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/restore.sh [--force] <backup-archive>

Examples:
  scripts/restore.sh backups/xmpp-backup-20260305T150000Z.tar.gz
  scripts/restore.sh --force xmpp-backup-20260305T150000Z.tar.gz
EOF
}

wait_for_postgres() {
  local tries=30
  local i
  for ((i = 1; i <= tries; i++)); do
    if compose_cmd exec -T postgres pg_isready -U "$POSTGRES_USER" -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: postgres is not ready after $tries attempts." >&2
  return 1
}

check_secret_file() {
  local secret_file="$1"
  if [ ! -s "$secret_file" ]; then
    echo "ERROR: required secret file missing or empty: $secret_file" >&2
    return 1
  fi
}

require_identifier() {
  local label="$1" value="$2"
  case "$value" in
    [A-Za-z_][A-Za-z0-9_]*)
      return 0
      ;;
    *)
      echo "ERROR: invalid ${label}: '$value'" >&2
      return 1
      ;;
  esac
}

confirm_restore() {
  local backup_path="$1"
  local answer
  if [ "$FORCE_RESTORE" -eq 1 ]; then
    return 0
  fi
  echo "Restore will replace database '$POSTGRES_DB' and project files in '$PROJECT_DIR'."
  echo "Backup: $backup_path"
  printf "Type 'restore' to continue: "
  read -r answer
  [ "$answer" = "restore" ] || {
    echo "Aborted."
    exit 1
  }
}

resolve_backup_path() {
  local input_path="$1"
  if [ -f "$input_path" ]; then
    printf '%s\n' "$input_path"
    return 0
  fi
  if [ -f "$PROJECT_DIR/backups/$input_path" ]; then
    printf '%s\n' "$PROJECT_DIR/backups/$input_path"
    return 0
  fi
  echo "ERROR: backup archive not found: $input_path" >&2
  return 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)
        FORCE_RESTORE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        echo "ERROR: unknown flag '$1'" >&2
        usage >&2
        exit 1
        ;;
      *)
        if [ -n "$BACKUP_PATH" ]; then
          echo "ERROR: only one backup archive is allowed." >&2
          usage >&2
          exit 1
        fi
        BACKUP_PATH="$1"
        shift
        ;;
    esac
  done

  if [ -z "$BACKUP_PATH" ]; then
    usage >&2
    exit 1
  fi

  BACKUP_PATH="$(resolve_backup_path "$BACKUP_PATH")"
}

main() {
  local tmp_dir metadata_db metadata_user

  maybe_reexec_with_sudo_if_env_unreadable "PROJECT_DIR,COMPOSE_FILE,ENV_FILE,SECRETS_DIR,POSTGRES_DB,POSTGRES_USER" "$@"
  load_env_file "$ENV_FILE" env_key_is_set

  POSTGRES_DB="${POSTGRES_DB:-prosody}"
  POSTGRES_USER="${POSTGRES_USER:-prosody}"
  SECRETS_DIR="${SECRETS_DIR:-$PROJECT_DIR/secrets}"

  parse_args "$@"

  require_identifier "POSTGRES_DB" "$POSTGRES_DB"
  require_identifier "POSTGRES_USER" "$POSTGRES_USER"
  check_secret_file "$SECRETS_DIR/postgres_password.txt"
  confirm_restore "$BACKUP_PATH"

  if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: compose file not found: $COMPOSE_FILE" >&2
    exit 1
  fi

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  tar -xzf "$BACKUP_PATH" -C "$tmp_dir"

  [ -f "$tmp_dir/postgres.dump" ] || { echo "ERROR: postgres.dump missing in archive." >&2; exit 1; }
  [ -f "$tmp_dir/prosody-files.tar.gz" ] || { echo "ERROR: prosody-files.tar.gz missing in archive." >&2; exit 1; }

  if [ -f "$tmp_dir/metadata.env" ]; then
    metadata_db="$(sed -n 's/^POSTGRES_DB=//p' "$tmp_dir/metadata.env" | head -n1)"
    metadata_user="$(sed -n 's/^POSTGRES_USER=//p' "$tmp_dir/metadata.env" | head -n1)"
    if [ -n "$metadata_db" ] && [ "$metadata_db" != "$POSTGRES_DB" ]; then
      echo "WARNING: backup DB '$metadata_db' differs from current '$POSTGRES_DB'."
    fi
    if [ -n "$metadata_user" ] && [ "$metadata_user" != "$POSTGRES_USER" ]; then
      echo "WARNING: backup DB user '$metadata_user' differs from current '$POSTGRES_USER'."
    fi
  fi

  compose_cmd stop prosody >/dev/null 2>&1 || true
  compose_cmd up -d postgres >/dev/null
  wait_for_postgres

  echo "Restoring project files..."
  tar -xzf "$tmp_dir/prosody-files.tar.gz" -C "$PROJECT_DIR"

  echo "Restoring PostgreSQL database..."
  compose_cmd exec -T -u postgres postgres dropdb --if-exists --force "$POSTGRES_DB"
  compose_cmd exec -T -u postgres postgres createdb --owner="$POSTGRES_USER" "$POSTGRES_DB"
  compose_cmd exec -T postgres pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges < "$tmp_dir/postgres.dump"

  compose_cmd up -d >/dev/null
  echo "Restore completed from: $BACKUP_PATH"
}

main "$@"
