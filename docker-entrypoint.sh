#!/bin/sh
set -eu

mkdir -p "$(dirname "${DB_URL}")"
export DATABASE_URL="sqlite:${DB_URL}"
dbmate --migrations-dir /app/migrations --no-dump-schema up

if [ "${LOAD_SAMPLE_DATA:-0}" = "1" ] && [ "$(sqlite3 "${DB_URL}" 'SELECT COUNT(*) FROM auth_user;')" = "0" ] || true; then
  sqlite3 "${DB_URL}" < /app/fixtures/sample-data.sql
fi

if [ "$#" -eq 0 ]; then
  set -- peachfuzz
fi

exec "$@"
