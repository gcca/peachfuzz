#!/bin/sh
set -eu

mkdir -p "$(dirname "${DBPATH}")"
export DATABASE_URL="sqlite:${DBPATH}"
dbmate --migrations-dir /app/migrations --no-dump-schema up

if [ "$#" -eq 0 ]; then
  set -- peachfuzz
fi

exec "$@"
