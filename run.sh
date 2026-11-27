#!/bin/bash
# First run installs the native services, later runs start the installed release.
set -euo pipefail
cd "$(dirname "$0")"
repo=$(pwd -P)
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 12 && $(dpkg --print-architecture) == amd64 ]] || {
    echo 'Use Debian 12 amd64 for this systemd host.' >&2; exit 2;
}
priv=()
(( EUID == 0 )) || priv=(sudo)
case ${1:-start} in
  stop) "${priv[@]}" systemctl stop kr-debian-game kr-debian-updates; exit ;;
  start|rebuild) ;;
  *) echo 'Usage: bash run.sh [start|stop|rebuild]' >&2; exit 2 ;;
esac
if (( $# > 2 )); then echo 'Usage: bash run.sh [start|rebuild] [PUBLIC_IPV4]' >&2; exit 2; fi
if [[ ${1:-start} == rebuild || ! -x /opt/kr-debian/current/bin/sprk-server ]]; then
    "${priv[@]}" bash deploy/debian/dependencies.sh
    if ! pg_lsclusters -h | awk '$1 == 18 && $2 == "main" {found=1} END {exit !found}'; then
        "${priv[@]}" pg_createcluster 18 main --start
    fi
    build_user=()
    if (( EUID == 0 )); then
        id kr-debian-build >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/cache/kr-debian-build kr-debian-build
        work=$(mktemp -d /var/tmp/kr-debian-build.XXXXXXXX)
        trap 'rm -rf -- "$work"' EXIT
        tar --exclude=.git --exclude=.env --exclude=target --exclude=artifacts --exclude=client-updates -cf - . | tar -xf - -C "$work"
        chown -R kr-debian-build: "$work"
        repo=$work
        build_user=(runuser -u kr-debian-build --)
    fi
    release="$repo/artifacts/native-$(date +%s)-$$"
    "${build_user[@]}" bash -eu -c '
        cd "$1"
        export PATH="$HOME/.cargo/bin:$PATH"
        if ! command -v rustup >/dev/null; then
            boot=$(mktemp)
            trap '\''rm -f "$boot"'\'' EXIT
            curl -fsSL --retry 3 https://sh.rustup.rs -o "$boot"
            sh "$boot" -y --profile minimal --default-toolchain 1.99.0
        else
            rustup toolchain install 1.99.0 --profile minimal
        fi
        bash deploy/debian/build.sh "$2"
    ' bash "$repo" "$release"
    "${priv[@]}" bash deploy/debian/install.sh "$release"
fi
if [[ ! -f /etc/kr-debian/eternal.env ]]; then
    "${priv[@]}" bash deploy/debian/set-eternal-registration.sh open
fi
"${priv[@]}" bash deploy/debian/configure-sea.sh "${2:-}"
"${priv[@]}" systemctl start kr-debian-updates kr-debian-game
for ((i=0; i<120; i++)); do
    if curl -fsS --max-time 2 http://127.0.0.1:8080/health/battle >/dev/null 2>&1 &&
       curl -fsS --max-time 4 http://127.0.0.1:8081/updates/stable/manifest.json >/dev/null 2>&1; then
        echo 'Debian game, battle worker and update service are ready.'
        if [[ -s /etc/kr-debian/sea-ip ]]; then
            host="$(cat /etc/kr-debian/sea-ip).sslip.io"
            check=(curl -fsS --max-time 10 --resolve "$host:443:127.0.0.1")
            "${check[@]}" "https://$host/host.json" | python3 -c '
import json, sys
s = json.load(sys.stdin)[0]["Server"][0]
if (s["Host"], s["Name"], s["LoginServer"], s["Https"]) != (sys.argv[1], "Eternal Fantasy - SEA", "https://" + sys.argv[1] + "/", True):
    sys.exit("Unexpected advertised game or login address")
' "$host"
            "${check[@]}" "https://$host/updates/stable/manifest.json" >/dev/null
            printf 'Game URL: https://%s/host.json\nUpdate manifest: https://%s/updates/stable/manifest.json\n' "$host" "$host"
        fi
        exit 0
    fi
    sleep 1
done
echo 'Startup timed out. Check journalctl -u kr-debian-game -u kr-debian-updates.' >&2
exit 1
