#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
case ${1:-} in
    open) allowed=true ;;
    closed) allowed=false ;;
    *) echo 'Usage: set-eternal-registration.sh open|closed' >&2; exit 2 ;;
esac
unit=kr-debian-game.service
dir=/etc/systemd/system/$unit.d
install -d -m755 "$dir" /etc/kr-debian
envfile=$(mktemp /etc/kr-debian/.eternal.XXXXXX)
dropin=$(mktemp "$dir/.eternal.XXXXXX")
trap 'rm -f "$envfile" "$dropin"' EXIT
printf '%s\n' 'SERVER_NAME="Eternal Fantasy - SEA"' "SPRK_ALLOW_REGISTRATION=$allowed" > "$envfile"
printf '%s\n' '[Service]' 'EnvironmentFile=/etc/kr-debian/eternal.env' > "$dropin"
chmod 644 "$envfile" "$dropin"
mv -f "$envfile" /etc/kr-debian/eternal.env
mv -f "$dropin" "$dir/70-eternal.conf"
systemctl daemon-reload
systemctl restart "$unit"
