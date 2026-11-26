#!/bin/bash
set -euo pipefail
cd /var/lib/kr-debian-backups
umask 077
tmp=$(mktemp .dump.XXXXXXXX)
trap 'rm -f -- "$tmp"' EXIT
pg_dump --format=custom --dbname="$DATABASE_URL" --file="$tmp"
pg_restore --list "$tmp" >/dev/null
mv "$tmp" "kr-debian-$(date -u +%Y%m%dT%H%M%SZ).dump"
find . -maxdepth 1 -type f -name 'kr-debian-*.dump' -mtime +13 -delete
