#!/usr/bin/env bash

load_env_file() {
  local file="$1" skip_callback="${2:-}" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    [ -z "${line//[[:space:]]/}" ] && continue
    case "$line" in
      [A-Za-z_][A-Za-z0-9_]*=*)
        key="${line%%=*}"
        value="${line#*=}"
        if [ -n "$skip_callback" ] && "$skip_callback" "$key"; then
          continue
        fi
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      *)
        ;;
    esac
  done < "$file"
}

env_key_is_set() {
  [ -n "${!1+x}" ]
}

init_root_cmd() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    ROOT_CMD=()
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    ROOT_CMD=(sudo)
  else
    ROOT_CMD=()
  fi
}

run_root() {
  "${ROOT_CMD[@]}" "$@"
}

compose_cmd() {
  if [ -f "${ENV_FILE:-}" ]; then
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

maybe_reexec_with_sudo_if_env_unreadable() {
  local preserve_env="$1"
  shift
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return 0
  fi
  if [ -f "${ENV_FILE:-}" ] && [ ! -r "$ENV_FILE" ] && command -v sudo >/dev/null 2>&1; then
    exec sudo --preserve-env="$preserve_env" "$0" "$@"
  fi
}
