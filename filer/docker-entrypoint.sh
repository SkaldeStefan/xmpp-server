#!/bin/sh
set -e
# Docker Compose v2 mounts secrets as read-only bind mounts; the filer user
# (non-root) cannot read root-owned files. Copy to a private tmpdir first.
_d="$(mktemp -d)"
install -m 400 -o filer /run/secrets/filer_secret         "$_d/filer_secret"
install -m 400 -o filer /run/secrets/storage_box_password "$_d/storage_box_password"
chown filer "$_d"
export FILER_SECRET_FILE="$_d/filer_secret"
export STORAGE_BOX_PASSWORD_FILE="$_d/storage_box_password"
exec gosu filer "$@"
