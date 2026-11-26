#!/bin/bash
# Install a prepared release on a Debian host running systemd and PostgreSQL 18.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run install.sh with sudo.' >&2; exit 1; }
src=$(realpath "${1:?Usage: install.sh PREPARED_RELEASE}")
units=$(cd "$(dirname "$0")" && pwd)
for part in bin/sprk-server bin/sprk-entrypoint bin/sprk-battle-worker bin/backup \
    client.env client-update-public.pem tables models "worker/King's Raid.exe"; do
    test -e "$src/$part" || { echo "Missing release component: $part" >&2; exit 1; }
done
[[ $(dpkg --print-architecture) == amd64 ]]
test -x /usr/lib/wine/wine64
command -v xvfb-run >/dev/null
exec 9>/run/lock/kr-debian-install.lock
flock -n 9 || { echo 'An installation is already running.' >&2; exit 1; }
systemctl start postgresql@18-main.service
psql_admin=(runuser -u postgres -- psql --cluster 18/main -X -v ON_ERROR_STOP=1 -d postgres)
port=$("${psql_admin[@]}" -Atc 'SHOW port')
if ! id kr-debian >/dev/null 2>&1; then
    adduser --system --group --home /var/lib/kr-debian --no-create-home kr-debian
fi
"${psql_admin[@]}" < "$units/database.sql"
dsn="postgresql://kr-debian@localhost:$port/kr_debian?host=/var/run/postgresql"
runuser -u kr-debian -- psql -X "$dsn" -Atc 'SELECT current_user' | grep -Fxq kr-debian
install -d -m755 /etc/kr-debian /opt/kr-debian/releases
printf 'DATABASE_URL=%s\n' "$dsn" > /etc/kr-debian/database.env.new
mv -f /etc/kr-debian/database.env.new /etc/kr-debian/database.env
release=$(mktemp -d /opt/kr-debian/releases/release.XXXXXXXX)
cp -R "$src/." "$release/"
chmod -R a+rX,go-w "$release"
install -m644 "$units"/*.service "$units"/*.timer /etc/systemd/system/
ln -s "$release" "$release.next"
mv -Tf "$release.next" /opt/kr-debian/current
systemctl daemon-reload
systemctl enable kr-debian-game.service kr-debian-updates.service kr-debian-backup.timer
systemctl restart kr-debian-game.service kr-debian-updates.service kr-debian-backup.timer
echo 'Services started. Checking battle readiness and the signed update manifest...'
for ((i=0; i<240; i++)); do
    if curl -fsS --max-time 4 http://127.0.0.1:8080/health/battle >/dev/null 2>&1 &&
       curl -fsS --max-time 4 http://127.0.0.1:8081/updates/stable/manifest.json >/dev/null 2>&1; then
        echo 'KR-Debian is ready.'
        exit 0
    fi
    sleep 5
done
echo 'Services did not become ready. Run journalctl -u kr-debian-game -u kr-debian-updates.' >&2
exit 1
