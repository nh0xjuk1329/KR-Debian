#!/bin/bash
# Configure the public launcher endpoint after the native services are installed.
set -euo pipefail
cd "$(dirname "$0")"
state=/etc/kr-debian
ip=${1:-}
if [[ -z $ip && -s $state/sea-ip ]]; then ip=$(cat "$state/sea-ip"); fi
if [[ -z $ip ]]; then
    # A UDP connect selects the outbound interface without sending a packet.
    ip=$(python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    try:
        sock.connect(("1.1.1.1", 443))
        print(sock.getsockname()[0])
    except OSError:
        pass
PY
    )
fi
if ! python3 - "$ip" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.IPv4Address(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if ip.is_global and not ip.is_multicast and not ip.is_reserved else 1)
PY
then
    if [[ -n ${1:-} || -s $state/sea-ip ]]; then echo 'Expected a public IPv4 address.' >&2; exit 2; fi
    echo 'Private network detected. Starting locally. For a VPS behind NAT, use bash run.sh start PUBLIC_IPV4.'
    exit 0
fi
host=$ip.sslip.io
if ! getent ahostsv4 "$host" | awk -v ip="$ip" '$1 == ip {ok=1} END {exit !ok}'; then
    echo "DNS does not resolve $host to $ip." >&2; exit 1
fi
exec 9>/run/lock/kr-debian-sea.lock
flock 9
if ! command -v nginx >/dev/null || ! command -v certbot >/dev/null; then
    apt-get update
    apt-get install -y --no-install-recommends nginx certbot
fi
webroot=/var/www/kr-debian-acme
install -d -m755 "$webroot"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
site=/etc/nginx/sites-enabled
apply_site() {
    local src=$1 dest=$2
    if cmp -s "$src" "$dest"; then return; fi
    if [[ -e $dest ]]; then cp "$dest" "$work/previous"; fi
    install -m644 "$src" "$dest"
    if ! nginx -t || ! systemctl reload-or-restart nginx; then
        if [[ -f $work/previous ]]; then cp "$work/previous" "$dest"; else rm -f "$dest"; fi
        echo "Failed to activate $dest. Check nginx and TCP ports 80 and 443." >&2; exit 1
    fi
    rm -f "$work/previous"
}
cat >"$work/http" <<EOF
server {
    listen 80;
    server_name $host;
    location ^~ /.well-known/acme-challenge/ { root $webroot; }
    location / { return 301 https://$host\$request_uri; }
}
EOF
systemctl enable --now nginx
apply_site "$work/http" "$site/kr-debian-acme"
certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
    --webroot -w "$webroot" -d "$host" --keep-until-expiring || {
    echo "Certificate issuance failed. Check that inbound TCP 80 reaches this machine at $ip, then rerun." >&2; exit 1;
}
sed "s/@HOST@/$host/g" sea-nginx.conf >"$work/https"
apply_site "$work/https" "$site/kr-debian-sea"
install -d /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nnginx -t && systemctl reload nginx\n' >"$work/renew"
install -m755 "$work/renew" /etc/letsencrypt/renewal-hooks/deploy/kr-debian-nginx
systemctl enable --now certbot.timer
dir=/etc/systemd/system/kr-debian-game.service.d
install -d "$dir"
cat >"$work/network" <<EOF
[Service]
EnvironmentFile=/etc/kr-debian/sea.env
EOF
printf 'SERVER_HOST=%s\nSERVER_HTTPS=true\nLOGIN_SERVER=https://%s/\nSPRK_WEBSOCKET_ORIGIN=wss://%s\n' "$host" "$host" "$host" >"$work/env"
if ! cmp -s "$work/network" "$dir/90-sea.conf" || ! cmp -s "$work/env" "$state/sea.env"; then
    install -m644 "$work/env" "$state/sea.env"
    install -m644 "$work/network" "$dir/90-sea.conf"
    systemctl daemon-reload
    systemctl restart kr-debian-game
fi
printf '%s\n' "$ip" >"$state/sea-ip"
