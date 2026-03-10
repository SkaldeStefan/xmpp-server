#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/lib/common.sh"

PROJECT_KEY="${1:-}"
PROJECT_SLUG="${PROJECT_SLUG:-xmpp-server}"

ENV_KEYS=(
  PROJECT_DIR
  SECRETS_DIR
  PROSODY_IMAGE
  POSTGRES_IMAGE
  PROSODY_DOMAIN
  PROSODY_ADMIN_JID
  POSTGRES_DB
  POSTGRES_USER
  BACKUP_RETENTION_DAYS
  STORAGE_BOX_URL
  STORAGE_BOX_USER
  UPLOAD_MAX_BYTES
  COTURN_IMAGE
  PROSODY_TURN_HOST
  TRAEFIK_NETWORK
  TRAEFIK_EXTERNAL
  TRAEFIK_CERT_RESOLVER
  TRAEFIK_ACME_JSON
  TRAEFIK_CERTS_DUMPER_IMAGE
  UPLOAD_DOMAIN
)

REQUIRED_ENV_KEYS=(
  PROJECT_DIR
  SECRETS_DIR
  PROSODY_IMAGE
  POSTGRES_IMAGE
  PROSODY_DOMAIN
  PROSODY_ADMIN_JID
  POSTGRES_DB
  POSTGRES_USER
  STORAGE_BOX_URL
  STORAGE_BOX_USER
  PROSODY_TURN_HOST
  TRAEFIK_NETWORK
  TRAEFIK_EXTERNAL
  TRAEFIK_ACME_JSON
  UPLOAD_DOMAIN
)

SECRET_FILES=(
  postgres_password.txt
  filer_secret.txt
  storage_box_password.txt
  turn_secret.txt
)

# Format: "source;destination_relative_to_PROJECT_DIR;mode"
STATIC_FILES=(
  "docker-compose.yml;docker-compose.yml;644"
  "docker-compose.local.yml;docker-compose.local.yml;644"
  "prosody/Dockerfile;prosody/Dockerfile;644"
  "prosody/docker-entrypoint.sh;prosody/docker-entrypoint.sh;755"
  "prosody-config/prosody.cfg.lua;prosody-config/prosody.cfg.lua;644"
  "prosody-config/modules/mod_http_upload_external.lua;prosody-config/modules/mod_http_upload_external.lua;644"
  "filer/Dockerfile;filer/Dockerfile;644"
  "filer/app.py;filer/app.py;644"
  "filer/requirements.txt;filer/requirements.txt;644"
  "filer/docker-entrypoint.sh;filer/docker-entrypoint.sh;755"
  "scripts/backup.sh;scripts/backup.sh;755"
  "scripts/restore.sh;scripts/restore.sh;755"
  "scripts/lib/common.sh;scripts/lib/common.sh;644"
)

PROTECTED_VARS=""
INSTALL_OWNER_UID="$(id -u)"
INSTALL_OWNER_GID="$(id -g)"

init_root_cmd

mark_protected_var() {
  local key="$1"
  if [ -n "${!key+x}" ]; then
    PROTECTED_VARS="$PROTECTED_VARS $key"
  fi
}

is_protected_var() {
  local key="$1"
  case " $PROTECTED_VARS " in
    *" $key "*) return 0 ;;
    *) return 1 ;;
  esac
}

should_skip_protected_env_key() {
  is_protected_var "$1"
}

require_var() {
  local key="$1"
  if [ -z "${!key:-}" ]; then
    echo "ERROR: $key is not set" >&2
    exit 1
  fi
}

ensure_env_key() {
  local env_file="$1" key="$2" value="${3:-}"
  if ! run_root grep -q "^${key}=" "$env_file"; then
    printf '%s=%s\n' "$key" "$value" | run_root tee -a "$env_file" >/dev/null
  fi
}

load_config_layers() {
  load_env_file ".env.defaults" should_skip_protected_env_key
  if [ -n "$PROJECT_KEY" ]; then
    load_env_file ".env.${PROJECT_KEY}" should_skip_protected_env_key
    load_env_file ".env.${PROJECT_KEY}.local" should_skip_protected_env_key
  else
    load_env_file ".env.local" should_skip_protected_env_key
  fi
}

derive_dirs() {
  if [ -n "$PROJECT_KEY" ]; then
    PROJECT_DIR="${PROJECT_DIR:-/srv/docker/projects/${PROJECT_SLUG}-${PROJECT_KEY}}"
    SECRETS_DIR="${SECRETS_DIR:-/etc/docker-secrets/${PROJECT_SLUG}-${PROJECT_KEY}}"
    export PROJECT_DIR SECRETS_DIR
  fi
}

install_static_files() {
  local item src dst mode dst_path
  for item in "${STATIC_FILES[@]}"; do
    IFS=';' read -r src dst mode <<< "$item"
    [ -f "$src" ] || continue
    dst_path="$PROJECT_DIR/$dst"
    run_root install -o "$INSTALL_OWNER_UID" -g "$INSTALL_OWNER_GID" -d -m 755 "$(dirname "$dst_path")"
    run_root install -o "$INSTALL_OWNER_UID" -g "$INSTALL_OWNER_GID" -m "$mode" "$src" "$dst_path"
  done
}

prepare_runtime_dirs() {
  run_root install -d -m 755 "$PROJECT_DIR/postgres-data"
  run_root install -d -m 755 "$PROJECT_DIR/prosody-data"
  run_root install -d -m 755 "$PROJECT_DIR/prosody-certs"
  run_root install -o "$INSTALL_OWNER_UID" -g "$INSTALL_OWNER_GID" -d -m 750 "$PROJECT_DIR/backups"
}

write_deploy_env() {
  local env_file="$PROJECT_DIR/.env" key
  if [ ! -f "$env_file" ]; then
    run_root install -o "$INSTALL_OWNER_UID" -g "$INSTALL_OWNER_GID" -m 600 /dev/null "$env_file"
  fi
  for key in "${ENV_KEYS[@]}"; do
    ensure_env_key "$env_file" "$key" "${!key:-}"
  done
  run_root chown "$INSTALL_OWNER_UID:$INSTALL_OWNER_GID" "$env_file"
  run_root chmod 600 "$env_file"
}

create_secret_placeholders() {
  local file
  run_root install -o "$INSTALL_OWNER_UID" -g "$INSTALL_OWNER_GID" -d -m 700 "$SECRETS_DIR"
  for file in "${SECRET_FILES[@]}"; do
    if [ ! -f "$SECRETS_DIR/$file" ]; then
      run_root install -o "$INSTALL_OWNER_UID" -g "$INSTALL_OWNER_GID" -m 600 /dev/null "$SECRETS_DIR/$file"
    else
      run_root chown "$INSTALL_OWNER_UID:$INSTALL_OWNER_GID" "$SECRETS_DIR/$file"
      run_root chmod 600 "$SECRETS_DIR/$file"
    fi
  done
}

main() {
  local key

  for key in "${ENV_KEYS[@]}"; do
    mark_protected_var "$key"
  done

  load_config_layers
  derive_dirs

  for key in "${REQUIRED_ENV_KEYS[@]}"; do
    require_var "$key"
  done

  run_root install -o "$INSTALL_OWNER_UID" -g "$INSTALL_OWNER_GID" -d -m 755 "$PROJECT_DIR"
  install_static_files
  prepare_runtime_dirs
  write_deploy_env
  create_secret_placeholders

  echo "Setup completed."
  echo "1) Set a strong DB password in: $SECRETS_DIR/postgres_password.txt"
  echo "2) Set a filer shared secret in: $SECRETS_DIR/filer_secret.txt  (e.g. openssl rand -hex 32)"
  echo "3) Set Hetzner Storage Box password in: $SECRETS_DIR/storage_box_password.txt"
  echo "4) Generate TURN secret in: $SECRETS_DIR/turn_secret.txt  (e.g. openssl rand -hex 32)"
  echo "5) Set PROSODY_TURN_HOST in $PROJECT_DIR/.env to the public IP/hostname of this server"
  echo "6) Check other non-sensitive values in: $PROJECT_DIR/.env"
  echo "7) Set TRAEFIK_EXTERNAL=true and TRAEFIK_NETWORK to your existing Traefik Docker network in $PROJECT_DIR/.env"
  echo "8) Set TRAEFIK_ACME_JSON in $PROJECT_DIR/.env to the absolute path of Traefik's acme.json"
  echo "9) Set UPLOAD_DOMAIN in $PROJECT_DIR/.env"
  echo "10) Build and start services from $PROJECT_DIR with: docker compose --profile traefik up -d --build"
  echo ""
  echo "Traefik endpoints:"
  echo "   Upload: https://${UPLOAD_DOMAIN}/"
}

main "$@"
