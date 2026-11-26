#!/bin/bash
# Prepare a self-contained native release as the build user.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=$(realpath -m "${1:?Usage: build.sh NEW_OUTPUT_DIRECTORY}")
[[ ! -e $out && ! -L $out ]] || { echo "Choose a fresh output directory: $out" >&2; exit 1; }
cd "$repo"
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "$(dirname "$out")/.kr-debian-build.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
release=$stage/release
mkdir -p "$release/bin"
tag=$(cat deploy/debian/client-release)
pin=config/worker-runtime.json
runtime_url=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print("https://github.com/{repository}/releases/download/{tag}/{asset}".format(**p))' "$pin")
curl --fail --location --retry 3 "$runtime_url" -o "$stage/runtime.tar.gz"
curl --fail --location --retry 3 "https://github.com/faberuser/sprk/releases/download/$tag/client-update.tar.gz" -o "$stage/client.tar.gz"
python3 server/scripts/worker/linux_worker.py build --tag "$tag" --runtime "$stage/runtime.tar.gz" \
    --release "$stage/client.tar.gz" --output "$release/worker"
python3 server/scripts/docker/prepare_illustration_runtime.py --server "$release/models"
cargo +1.99.0 build --release --locked --target-dir "$repo/target"
install -m755 target/release/sprk-server "$release/bin/"
install -m755 deploy/debian/backup.sh "$release/bin/backup"
install -m755 server/scripts/docker/docker-entrypoint.sh "$release/bin/sprk-entrypoint"
install -m755 server/scripts/docker/docker-battle-worker.sh "$release/bin/sprk-battle-worker"
install -m644 config/client-update-public.pem "$release/"
cp -R server/tables "$release/tables"
printf 'SPRK_UPDATES_GITHUB_TAG=%s\n' "$tag" > "$release/client.env"
mv -T "$release" "$out"
echo "Native release ready at $out"
