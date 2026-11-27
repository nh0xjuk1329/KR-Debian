"""Native Windows host for a single KR-Debian checkout (invoked by start_server.bat)."""
import csv
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from server.scripts.worker.linux_worker import assemble, apply_release
from client.scripts.release.client_update_bundle import verified_manifest

TOOLS = Path(os.environ["LOCALAPPDATA"]) / "KR-Debian/tools"
INSTANCE = hashlib.sha256(str(REPO).casefold().encode()).hexdigest()[:12]
STATE = TOOLS.parent / "servers" / INSTANCE
ART = REPO / "artifacts/windows"
CACHE = REPO / "artifacts/native-downloads"
KEY = REPO / "config/client-update-public.pem"
PG = "postgresql-18.7-2-windows-x64-binaries.zip"
PG_HASH = "74f3740a2e7844118857f297c2067d226f8f2b0652de96022ce54bb27cd60a79"
GAME_PORT = 8180
DB_PORT = 54320


def fetch(file, url):
    if not file.exists():
        file.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=file.parent) as work:
            part = Path(work) / "download"
            subprocess.run(["curl.exe", "-fsSL", "--retry", "3", url, "-o", part], check=True)
            part.replace(file)
    return file


def pg_bin():
    target = TOOLS / PG.removesuffix(".zip")
    if not target.exists():
        archive = fetch(TOOLS / PG, "https://get.enterprisedb.com/postgresql/" + PG)
        with archive.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != PG_HASH:
                raise ValueError(f"PostgreSQL checksum mismatch: {archive}")
        with tempfile.TemporaryDirectory(dir=TOOLS) as work, zipfile.ZipFile(archive) as package:
            for name in package.namelist():
                if name.startswith(("pgsql/bin/", "pgsql/share/", "pgsql/lib/")):
                    package.extract(name, work)
            (Path(work) / "pgsql").rename(target)
    return target / "bin"


def runtime():
    tag = (REPO / "deploy/debian/client-release").read_text().strip()
    version = tag.removeprefix("client-")
    pin = json.loads((REPO / "config/worker-runtime.json").read_text())
    worker = ART / pin["tag"] / tag
    updates = ART / "updates"
    release = updates / "releases" / version
    if not worker.exists() or not release.exists():
        snapshot = fetch(CACHE / tag / "client-update.tar.gz",
                         f"https://github.com/faberuser/sprk/releases/download/{tag}/client-update.tar.gz")
        if not worker.exists():
            archive = fetch(CACHE / pin["tag"] / pin["asset"],
                            "https://github.com/{repository}/releases/download/{tag}/{asset}".format(**pin))
            assemble(worker, archive, snapshot, pin, KEY, tag)
        if not release.exists():
            release.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(dir=release.parent) as work:
                temp = Path(work) / "release"
                files = temp / "files"
                files.mkdir(parents=True)
                raw = apply_release(snapshot, files, KEY, tag)
                (temp / "manifest.json").write_bytes(raw)
                temp.rename(release)
    raw = (release / "manifest.json").read_bytes()
    manifest = verified_manifest(raw, KEY)
    if manifest["version"] != version:
        raise ValueError("Installed manifest differs from pinned client release")
    stable = updates / "stable"
    stable.mkdir(exist_ok=True)
    tmp = stable / "manifest.new"
    tmp.write_bytes(raw)
    tmp.replace(stable / "manifest.json")
    return worker / "King's Raid.exe", updates


def private_state():
    STATE.mkdir(parents=True, exist_ok=True)
    who = subprocess.check_output(["whoami", "/user", "/fo", "csv", "/nh"], text=True)
    sid = next(csv.reader([who.strip()]))[1]
    subprocess.run(["icacls", STATE, "/inheritance:r", "/grant:r", f"*{sid}:(OI)(CI)F",
                    "*S-1-5-18:(OI)(CI)F"], check=True, stdout=subprocess.DEVNULL)


def asset_origin(updates):
    configured = os.environ.get("SPRK_ASSETS_CDN_URL")
    if configured:
        return configured
    store = updates / "assets"
    current = store / "StandaloneWindows/current.txt"
    if not current.exists():
        from client.scripts.release.publish_assets import publish
        for name in ("sprk-client", "Kings Raid Eternal"):
            source = REPO.parent / name
            if (source / "King's Raid_Data/Documents/Patch/StandaloneWindows/Assetbundle/BundlePack.bin").is_file():
                print("Preparing the local Windows asset library from the installed client.", flush=True)
                publish(source, store, "StandaloneWindows", version=6)
                break
    if current.is_file():
        return f"http://127.0.0.1:{GAME_PORT}/updates/assets/"
    return "https://updates.krinfo.net/updates/assets/"


def worker_audio(worker):
    audio = TOOLS / "audio"
    if not (audio / "pycaw/pycaw.py").is_file():
        subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
                        "--target", audio, "pycaw==20260927"], check=True)
    sys.path.insert(0, str(audio))
    from pycaw.pycaw import AudioUtilities
    from comtypes import COMError
    import psutil

    def mute():
        try:
            sessions = AudioUtilities.GetAllSessions()
        except (COMError, OSError):
            return False  # A Windows host can run without a sound device.
        for session in sessions:
            try:
                process = session.Process
                if process and Path(process.exe()) == worker:
                    session.SimpleAudioVolume.SetMute(1, None)
                    return True
            except (psutil.NoSuchProcess, psutil.AccessDenied, COMError, OSError):
                continue
        return False
    return mute


def credential(name):
    path = STATE / name
    if not path.exists():
        tmp = path.with_suffix(".new")
        tmp.write_text(secrets.token_hex(32), encoding="ascii")
        tmp.replace(path)
    return path


def serve():
    private_state()
    with (STATE / "host.lock").open("a+b") as lock:
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            raise SystemExit("Local is already starting or running.")
        stop = STATE / "stop"
        stop.unlink(missing_ok=True)
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            probe.bind(("127.0.0.1", GAME_PORT))
        worker, updates = runtime()
        cdn = asset_origin(updates)
        mute = worker_audio(worker)
        pg = pg_bin()
        cluster = STATE / "postgres"
        admin = credential("db-admin.key")
        game_pw = credential("db-game.key").read_text()
        if not cluster.exists():
            with tempfile.TemporaryDirectory(dir=STATE) as work:
                data = Path(work) / "data"
                subprocess.run([pg / "initdb.exe", "-D", data, "-U", "postgres", "-A", "scram-sha-256",
                                "--pwfile", admin, "--locale=C", "-E", "UTF8"], check=True)
                data.rename(cluster)
        ctl = [pg / "pg_ctl.exe", "-D", cluster, "-w"]
        subprocess.run(ctl + ["-l", STATE / "postgres.log", "-o", f"-h 127.0.0.1 -p {DB_PORT}", "start"], check=True)
        game = None
        try:
            # Use the same least-privileged role and ownership checks as Debian.
            psql = [pg / "psql.exe", "-X", "-v", "ON_ERROR_STOP=1", "-h", "127.0.0.1", "-p", str(DB_PORT),
                    "-U", "postgres", "-d", "postgres"]
            sql = (REPO / "deploy/debian/database.sql").read_text()
            sql += f'\nALTER ROLE "kr-debian" PASSWORD \'{game_pw}\';\n'
            subprocess.run(psql, input=sql, text=True, env=dict(os.environ, PGPASSWORD=admin.read_text()),
                           check=True, stdout=subprocess.DEVNULL)
            origin = f"127.0.0.1:{GAME_PORT}"
            env = dict(os.environ, PORT=str(GAME_PORT), SERVER_NAME="Local", SERVER_HOST=origin, SERVER_HTTPS="false",
                       LOGIN_SERVER=f"http://{origin}/", SPRK_WEBSOCKET_ORIGIN=f"ws://{origin}",
                       SPRK_SERVICE_MODE="all", SPRK_HTTP_BIND="127.0.0.1", CHAT_BIND="127.0.0.1", BATTLE_BIND="127.0.0.1",
                       GAME_TABLES_PATH=str(REPO / "server/tables"), SPRK_UPDATES_DIR=str(updates),
                       BATTLE_WORKER_EXECUTABLE=str(worker), BATTLE_SERVICE_KEY_FILE=str(credential("battle.key")),
                       DATABASE_URL=f"postgres://kr-debian:{game_pw}@127.0.0.1:{DB_PORT}/kr_debian")
            env.pop("SPRK_UPDATES_GITHUB_TAG", None)
            env["SPRK_ASSETS_CDN_URL"] = cdn
            with (STATE / "server.log").open("ab") as log:
                game = subprocess.Popen([REPO / "target/release/sprk-server.exe"], env=env, cwd=STATE,
                                        stdout=log, stderr=log)
                deadline = time.monotonic() + 120
                muted = False
                while game.poll() is None and not stop.exists():
                    if not muted:
                        muted = mute()
                    try:
                        with urllib.request.urlopen(f"http://{origin}/health/battle", timeout=2) as response:
                            if response.status == 200:
                                break
                    except OSError:
                        pass
                    if time.monotonic() > deadline:
                        raise RuntimeError(f"Battle service startup timed out. See {STATE / 'server.log'}")
                    time.sleep(.5)
                if game.poll() is None and not stop.exists():
                    if not muted:
                        mute()
                    print(f"Local is ready at http://{origin}. Press Ctrl+C to stop. Logs: {STATE}", flush=True)
                while game.poll() is None and not stop.exists():
                    time.sleep(.5)
                if game.poll() is not None:
                    raise RuntimeError(f"Server exited ({game.returncode}). See {STATE / 'server.log'}")
        finally:
            if game is not None and game.poll() is None:
                game.terminate()
                game.wait()
            subprocess.run(ctl + ["stop", "-m", "fast"], check=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["stop"]:
        if STATE.is_dir():
            (STATE / "stop").touch()
    else:
        try:
            serve()
        except KeyboardInterrupt:
            pass
