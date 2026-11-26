#!/bin/bash
set -euo pipefail
. /etc/os-release
if [[ $EUID != 0 || $ID != debian || $VERSION_ID != 12 || $(dpkg --print-architecture) != amd64 ]]; then
    echo 'Run as root on Debian 12 (Bookworm), amd64.' >&2
    exit 1
fi
apt-get update
apt-get install -y --no-install-recommends build-essential cmake pkg-config perl \
    ca-certificates curl openssl python3 wine64 xvfb xauth fonts-liberation \
    postgresql-common gnupg
if ! apt-cache show postgresql-18 >/dev/null 2>&1; then
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
fi
apt-get install -y --no-install-recommends postgresql-18 postgresql-client-18
