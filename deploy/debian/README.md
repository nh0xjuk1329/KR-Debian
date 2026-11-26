# Host KR-Debian

Use a Debian 12 (Bookworm) amd64 host with systemd, internet access, and room
for a Rust release build, Unity worker, client updates, and database backups.
Players use the full Windows client. The server runs with PostgreSQL 18 and
uses a signed upstream client release pinned in `client-release`.

## Install

From a regular login with sudo access:

```sh
sudo apt-get update && sudo apt-get install -y git
git clone --branch debian https://github.com/nh0xjuk1329/KR-Debian.git
cd KR-Debian
sudo bash deploy/debian/dependencies.sh
```

The dependency script installs the compiler prerequisites, PostgreSQL, Wine64,
and Xvfb. It enables the PostgreSQL project's apt repository if the configured
sources do not provide version 18. Check that `pg_lsclusters` lists `18 main`.
If PostgreSQL is configured to skip automatic cluster creation, run
`sudo pg_createcluster 18 main --start` once.

Install the build toolchain as your regular user. On a machine that already
has rustup, use `rustup toolchain install 1.99.0 --profile minimal` and skip
the rustup installer.

```sh
curl -fsSLo /tmp/kr-rustup.sh https://sh.rustup.rs
sh /tmp/kr-rustup.sh -y --profile minimal --default-toolchain 1.99.0
. "$HOME/.cargo/env"
bash deploy/debian/build.sh artifacts/first-release
sudo bash deploy/debian/install.sh artifacts/first-release
```

The build compiles this checkout's Rust code and verifies the worker archive
and client signature before installing any runtime files. The installer
creates the `kr-debian` system user, a restricted PostgreSQL login of the same
name, and the `kr_debian` database it owns. The services connect over the
local PostgreSQL socket using Debian's peer authentication. This personal-host
setup uses the database owner for both migrations and gameplay.

The installer starts the game and update services and waits for the battle
worker and launcher manifest. The first start downloads the pinned release.
To inspect readiness or diagnose a startup failure:

```sh
curl -f http://127.0.0.1:8080/health/battle
curl -f http://127.0.0.1:8081/updates/stable/manifest.json -o /dev/null
sudo journalctl -u kr-debian-game -u kr-debian-updates -n 80
```

## Play from Windows

The default listeners are private to the Debian host. In PowerShell on the
Windows PC, open an SSH tunnel and keep it open while playing. Substitute your
Debian login and host for `user@debian-host`.

```powershell
ssh -o ExitOnForwardFailure=yes -N -L 127.0.0.1:8080:127.0.0.1:8080 -L 127.0.0.1:8081:127.0.0.1:8081 user@debian-host
```

Open `SprkLauncher.exe`, choose **Local**, and click **Update and Play**.
Ports 8080 and 8081 on Windows must be free. The launcher downloads signed
code updates. Use a full client with its game assets for this setup.

## Customize and maintain

- **Server name.** Set `SERVER_NAME="My King's Raid"` in
  `/etc/kr-debian/game.env`, then run `sudo systemctl restart kr-debian-game`.
  For access through a public HTTPS reverse proxy, set `SERVER_HOST` and
  `SERVER_HTTPS=true` to advertise your game endpoint, proxy WebSocket
  upgrades, and create a launcher profile for your HTTPS game and update URLs.
- **Game data.** PostgreSQL keeps accounts and progress. The persistent battle
  key and Wine prefix live in `/var/lib/kr-debian`. The update service manages
  its own cache in `/var/lib/kr-debian-updates`.
- **Backups.** `kr-debian-backup.timer` writes a PostgreSQL custom-format
  dump at 04:00 UTC daily to `/var/lib/kr-debian-backups`, with 14 days'
  retention. Run `sudo systemctl start kr-debian-backup` for an immediate dump.
  Keep a copy off the server before an upgrade.
- **Upgrades.** Pull your changes, build to a new output directory, and run
  the installer again with that directory. It keeps database contents, keys,
  and operator settings. Each installed build lives in `/opt/kr-debian/releases`.
  Database migrations can affect compatibility with older builds.
- **Client compatibility.** When updating the pin, choose the signed upstream
  client tag matching the server revision. Both the worker and update service
  use that tag and the repository's public key. For hosting additional asset
  bundles see the [asset guide](../../docs/game-assets.md).
