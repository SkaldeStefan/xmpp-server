#!/bin/bash
set -e

# Fix ownership of runtime directories instead of changing the prosody UID.
# The upstream entrypoint tries "usermod -u <owner> prosody" which breaks
# when the data dir is owned by root (UID 0).
chown prosody:prosody /var/lib/prosody /var/run/prosody

# Docker Compose v2 mounts secrets as root-owned bind mounts.
# Copy them to a private tmpdir readable by the prosody user.
_d="$(mktemp -d)"
for secret in postgres_password filer_secret turn_secret; do
    src="/run/secrets/$secret"
    if [ -f "$src" ]; then
        install -m 400 -o prosody "$src" "$_d/$secret"
    fi
done
chown prosody "$_d"
export PROSODY_DB_PASSWORD_FILE="$_d/postgres_password"
export PROSODY_FILER_SECRET_FILE="$_d/filer_secret"
export PROSODY_TURN_SECRET_FILE="$_d/turn_secret"

# prosodyctl pass-through (e.g. "docker exec ... adduser user@domain")
if [[ "$1" != "prosody" ]]; then
    exec prosodyctl "$@"
fi

# Optional: register a user on first start via environment variables
if [[ "$LOCAL" && "$PASSWORD" && "$DOMAIN" ]]; then
    prosodyctl register "$LOCAL" "$DOMAIN" "$PASSWORD"
fi

exec runuser -u prosody -- "$@"
