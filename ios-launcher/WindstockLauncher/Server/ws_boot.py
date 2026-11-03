"""
ws_boot -- run the Windstock server inside the launcher app.

The server was written to be a program you double-click on a desktop: it writes
beside itself, it reads certs beside itself, and main() blocks forever. Inside
an iOS app none of that holds -- the bundle is read-only, there is no cwd worth
having, and the UI needs to be able to stop and restart the thing. So rather
than forking server.py (which the project keeps improving), this module bends
the environment around it before importing it:

  * datadir.DATA_DIR is repointed at a writable container directory, before
    anything that snapshots it at import time (settings.py does) is imported;
  * socketserver.BaseServer.serve_forever is wrapped so we get a handle on the
    server object main() creates locally, which is the only way to shut it down;
  * stdout/stderr go to the launcher's log pipe.

Nothing here imports UIKit or knows about the app. It is driven entirely by
environment variables set by WSPythonServer.m.
"""
import os
import sys
import threading
import traceback

STATE = {
    "httpd": None,
    "servers": [],
    "plain_port": None,
    "admin_port": None,
    "thread": None,
    "running": False,
    "error": None,
    "port": None,
    "installed": False,
    "stopping": False,
    "revive_lock": threading.Lock(),
    # What the listeners are: "server" (the game server on this phone) or
    # "tunnel:<ip:port>" (Windstock Online -- tunnel.py). start() compares it
    # with what is wanted now, so switching modes is just start() again.
    "mode": None,
}


def _log(msg):
    print(f"[boot] {msg}", flush=True)


def _install_env():
    """Environment defaults that run.py sets for the desktop launcher.

    The app imports this module and calls start() directly, so nothing in
    run.py ever executes and every default it sets there has to be repeated
    here or it silently does not apply. SERVE_GAME_MASTER is the one that
    bites: without it DOWNLOAD_ITEM_TEMPLATES answers with a 32-byte
    placeholder set, and a client with no PokemonSettings will not instantiate
    a single Pokemon or fort model -- GET_MAP_OBJECTS lands fine, and the map
    still draws empty apart from the base rings, which are built into the app.

    setdefault throughout: WSPythonServer.m has already setenv'd the values it
    owns (PORT, BIND, CERT_DIR) and those must win.
    """
    os.environ.setdefault("SERVE_GAME_MASTER", "1")
    os.environ.setdefault("BIND", "127.0.0.1")
    os.environ.setdefault("PORT", "8443")


def _install_stdio():
    """Point stdout/stderr at the pipe the app handed us in WS_LOG_FD."""
    fd = os.environ.get("WS_LOG_FD")
    if not fd:
        return
    try:
        stream = os.fdopen(int(fd), "w", buffering=1, errors="replace")
    except OSError:
        return
    sys.stdout = stream
    sys.stderr = stream


def _install_paths():
    root = os.environ["WS_SERVER_DIR"]
    for p in (root, os.path.join(root, "vendor")):
        if p not in sys.path:
            sys.path.insert(0, p)


class _FrameworkFinder:
    """Import C extension modules that were packaged as iOS frameworks.

    iOS app bundles only get their Mach-O files code-signed when they sit in
    Frameworks/ as a framework, so tools/stage_python.sh turns every
    lib-dynload/<name>.cpython-313-iphoneos.so into
    Frameworks/<name>.framework/<name>. CPython has no idea about that layout,
    so we teach it: this finder maps `import _ssl` to that binary.
    """

    def __init__(self, frameworks_dir):
        self.dir = frameworks_dir

    def find_spec(self, fullname, path=None, target=None):
        if "." in fullname:
            return None
        binary = os.path.join(self.dir, fullname + ".framework", fullname)
        if not os.path.isfile(binary):
            return None
        import importlib.machinery
        import importlib.util
        loader = importlib.machinery.ExtensionFileLoader(fullname, binary)
        return importlib.util.spec_from_file_location(fullname, binary, loader=loader)


def _install_binary_modules():
    frameworks = os.environ.get("WS_FRAMEWORKS_DIR")
    if not frameworks or not os.path.isdir(frameworks):
        return
    sys.meta_path.append(_FrameworkFinder(frameworks))


def _install_datadir():
    """Repoint the server's data folder into the writable container.

    Must happen before `settings`, `places`, `protocol` and friends are
    imported: several of them evaluate datadir.path(...) at module scope, and
    that value is then frozen for the life of the process.
    """
    import datadir

    writable = os.environ["WS_DATA_DIR"]
    os.makedirs(writable, exist_ok=True)
    _seed(writable)
    datadir.DATA_DIR = writable
    datadir.base_dir = lambda: os.path.dirname(writable)
    datadir._ready = True          # skip the desktop-layout migration entirely
    _log(f"data dir -> {writable}")


def _seed(writable):
    """First run: copy the shipped settings/places/gyms into the writable dir.

    Only files that are not there yet, so a save never gets overwritten by an
    app update.
    """
    seed = os.path.join(os.environ["WS_SERVER_DIR"], "seed-data")
    if not os.path.isdir(seed):
        return
    import shutil
    copied = []
    for name in os.listdir(seed):
        target = os.path.join(writable, name)
        if os.path.exists(target):
            continue
        try:
            # copyfile, not copy2: copying the xattrs (security.selinux) is EACCES on Android,
            # which logged "could not seed" for files that HAD been copied
            shutil.copyfile(os.path.join(seed, name), target)
            copied.append(name)
        except OSError as exc:
            _log(f"could not seed {name}: {exc}")
    if copied:
        _log("seeded " + ", ".join(sorted(copied)))
    _merge_seed_settings(seed, writable)


def _merge_seed_settings(seed, writable):
    """Add settings the shipped seed has and the saved file does not.

    The copy above deliberately never overwrites, so a settings.json written by
    an older build keeps whatever the player changed -- but it also never gains
    anything added since. settings.py back-fills missing keys from its own code
    defaults, which are not the same values: progression.run_tutorial defaults
    to False there while the shipped config turns it on, so onboarding stayed
    off on every upgraded install.

    Only keys ABSENT from the saved file are added. Anything already in it wins,
    so this can never undo a change made in the World Manager.
    """
    import json

    target = os.path.join(writable, "settings.json")
    source = os.path.join(seed, "settings.json")
    if not (os.path.isfile(target) and os.path.isfile(source)):
        return
    try:
        with open(target, encoding="utf-8") as fh:
            user = json.load(fh)
        with open(source, encoding="utf-8") as fh:
            shipped = json.load(fh)
    except (OSError, ValueError) as exc:
        _log(f"could not merge settings: {exc}")
        return

    added = []
    for section, values in shipped.items():
        if not isinstance(values, dict):
            continue
        if not isinstance(user.get(section), dict):
            user[section] = values
            added.append(section)
            continue
        for key, value in values.items():
            if key not in user[section]:
                user[section][key] = value
                added.append(f"{section}.{key}")
    if not added:
        return
    try:
        with open(target, "w", encoding="utf-8") as fh:
            json.dump(user, fh, indent=2)
    except OSError as exc:
        _log(f"could not write merged settings: {exc}")
        return
    _log(f"settings: added {len(added)} new key(s) -- " + ", ".join(added[:6])
         + (" ..." if len(added) > 6 else ""))


def _server_port(srv):
    try:
        return srv.server_address[1]
    except (AttributeError, IndexError, TypeError):
        return None


def _main_server():
    """The TLS game listener -- the one the UI reports as "the server"."""
    for srv in list(STATE["servers"]):
        if _server_port(srv) == STATE["port"]:
            return srv
    return None


def _install_server_handle():
    """Capture every HTTPServer the server modules build and never expose.

    server.main(), the plain listener and admin.serve() all end up in
    serve_forever, so hooking it is the one place that sees all three -- which
    is what lets stop() stop them all and revive() rebuild them.
    """
    import socketserver

    original = socketserver.BaseServer.serve_forever

    def serve_forever(self, *args, **kwargs):
        if self not in STATE["servers"]:            # revive() registers early
            STATE["servers"].append(self)
        if _server_port(self) == STATE["port"]:
            STATE["httpd"] = self
            STATE["running"] = True
        try:
            return original(self, *args, **kwargs)
        finally:
            if self in STATE["servers"]:
                STATE["servers"].remove(self)
            if STATE["httpd"] is self:
                STATE["httpd"] = None
                STATE["running"] = False

    socketserver.BaseServer.serve_forever = serve_forever


# ---------------------------------------------------------------- waking up
#
# iOS reclaims a suspended app's LISTENING sockets. Lock the phone for a few
# minutes and every listener is quietly defunct: the process, the threads and
# the server objects are all fine, the UI still says "running", and every
# connect from the game fails at once ("Could not connect to the server" in
# the launcher log, 2026-09-26, after each lock). Nothing in Python notices,
# so nothing ever recovers. revive() probes each listener and rebuilds the
# dead ones on the same port; the app calls it on every return to the
# foreground, and a watchdog calls it when the clock jumps (= we were frozen).

def _probe(srv):
    """Can a client actually connect and be served? Never raises."""
    import socket
    import ssl

    port = _server_port(srv)
    if not port:
        return True
    host = "127.0.0.1"
    try:
        raw = socket.create_connection((host, port), timeout=1.5)
    except OSError:
        return False
    try:
        # A bare connect-and-close to the TLS port makes the server log a
        # failed handshake, so finish one properly and hang up.
        if isinstance(srv.socket, ssl.SSLSocket):
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            try:
                ctx.minimum_version = ssl.TLSVersion.TLSv1
                ctx.set_ciphers("DEFAULT:@SECLEVEL=0")
            except (ssl.SSLError, ValueError):
                pass
            raw.settimeout(3)
            try:
                ctx.wrap_socket(raw).close()
            except (ssl.SSLError, OSError):
                return False
        return True
    finally:
        try:
            raw.close()
        except OSError:
            pass


def _rebuild(old):
    """A fresh listener with the same class, address, handler and TLS."""
    import ssl

    new = type(old)(old.server_address, old.RequestHandlerClass)
    if isinstance(old.socket, ssl.SSLSocket):
        new.socket = old.socket.context.wrap_socket(
            new.socket, server_side=True, do_handshake_on_connect=True)
    return new


def revive(reason="foreground"):
    """Rebuild any listener iOS took away while we were suspended."""
    if STATE["stopping"] or not STATE["servers"]:
        return 0
    if not STATE["revive_lock"].acquire(blocking=False):
        return 0                       # one pass at a time; the other is doing it
    fixed = 0
    try:
        for old in list(STATE["servers"]):
            if _probe(old):
                continue
            port = _server_port(old)
            _log(f"listener on :{port} is dead after {reason} -- rebuilding it")
            is_main = old is STATE["httpd"]
            if old in STATE["servers"]:
                STATE["servers"].remove(old)
            if is_main:
                STATE["httpd"] = None
            # End the old loop BEFORE closing its socket: a select() on a
            # closed fd raises out of serve_forever and would be reported as
            # a server crash. shutdown() waits for the loop, so bound it.
            stopper = threading.Thread(target=old.shutdown, daemon=True)
            stopper.start()
            stopper.join(2)
            try:
                old.server_close()
            except Exception:                              # noqa: BLE001
                pass
            new = None
            for attempt in range(10):
                try:
                    new = _rebuild(old)
                    break
                except OSError as exc:
                    if attempt == 9:
                        _log(f"could not rebind :{port}: {exc}")
                    import time
                    time.sleep(0.3)
            if new is None:
                if is_main:
                    STATE["running"] = False
                    STATE["error"] = f"Could not reopen port {port} after sleep."
                continue
            # Registered before its thread runs, so status() never sees a gap
            # and the launcher's redirect never flips off mid-swap.
            STATE["servers"].append(new)
            if is_main:
                STATE["httpd"] = new
                STATE["running"] = True
                STATE["error"] = None
            threading.Thread(target=new.serve_forever, daemon=True,
                             name=f"windstock-listener-{port}").start()
            fixed += 1
        if fixed:
            _log(f"revived {fixed} listener(s)")
    finally:
        STATE["revive_lock"].release()
    return fixed


def _watchdog():
    """Notices a suspension from the inside: the clock jumps while we sleep."""
    import time

    last = time.time()
    while True:
        time.sleep(2)
        now = time.time()
        if now - last > 10:
            try:
                revive(f"a {int(now - last)} s pause")
            except Exception as exc:                       # noqa: BLE001
                _log(f"revive failed: {exc}")
        last = now


def _start_plain_http():
    """A second listener that does NOT wrap the socket in TLS.

    The iOS client is patched to reach the SSO over plain http -- the
    metadata has http://pgorelease.nianticlabs.com/sso/login -- so it dials
    port 80, while server.main() wraps every connection it accepts in TLS.
    Same Handler, same routing, no TLS.
    """
    port = int(os.environ.get("WS_HTTP_PORT", "8080"))
    bind = os.environ.get("BIND", "127.0.0.1")
    import server

    httpd = server.ThreadingHTTPServer((bind, port), server.Handler)
    STATE["plain_port"] = port
    thread = threading.Thread(target=httpd.serve_forever, daemon=True,
                              name="windstock-http")
    thread.start()
    _log(f"plain HTTP listener on {bind}:{port}")


def _start_admin():
    """The World Manager -- the game editor the Settings tab embeds.

    run.py is the only thing that ever started this, so the launcher shipped
    without it. Its default port is 8080, which the plain HTTP listener above
    already owns, so it gets its own (WS_ADMIN_PORT, default 8081). Bound to
    127.0.0.1: it has no authentication and is meant to be reachable only from
    this device.
    """
    port = int(os.environ.get("WS_ADMIN_PORT", "8081"))
    import admin

    admin.start(port=port, host="127.0.0.1")
    STATE["admin_port"] = port
    _log(f"game editor on 127.0.0.1:{port}")


def _wanted_mode():
    target = (os.environ.get("WS_TUNNEL_TARGET") or "").strip()
    return f"tunnel:{target}" if target else "server"


def configure_tunnel(target):
    """Choose what the next start() runs: "" for the game server on this phone,
    "ip:port" for the encrypted tunnel to a Windstock Online server.

    A function rather than an environment variable the app sets, because
    os.environ is a snapshot taken when the interpreter started -- a setenv()
    made by the app afterwards never shows up in it."""
    target = (target or "").strip()
    if target:
        os.environ["WS_TUNNEL_TARGET"] = target
    else:
        os.environ.pop("WS_TUNNEL_TARGET", None)
    return _wanted_mode()


def forget_online_certificate():
    """Drop the certificate saved for the current Online server (tunnel.py)."""
    try:
        import tunnel
        return bool(tunnel.forget())
    except Exception as exc:                          # noqa: BLE001
        _log(f"could not forget the certificate: {exc}")
        return False


def _run_tunnel(target):
    """Windstock Online: the same two loopback ports, but a tunnel behind them
    instead of the game server. No game editor -- there is no game here to edit."""
    import tunnel
    cert_dir = os.environ.get("CERT_DIR", "")
    STATE["plain_port"] = int(os.environ.get("WS_HTTP_PORT", "8080"))
    STATE["admin_port"] = None
    tunnel.serve(target,
                 bind=os.environ.get("BIND", "127.0.0.1"),
                 port=STATE["port"], plain_port=STATE["plain_port"],
                 cert=os.path.join(cert_dir, "server.crt"),
                 key=os.path.join(cert_dir, "server.key"))


def _run():
    try:
        if STATE["mode"].startswith("tunnel:"):
            _run_tunnel(STATE["mode"][len("tunnel:"):])
            return
        import server
        try:
            _start_plain_http()
        except OSError as exc:
            _log(f"could not start the plain HTTP listener: {exc}")
        try:
            _start_admin()
        except Exception as exc:                      # noqa: BLE001
            _log(f"could not start the game editor: {exc}")
        server.main()
    except SystemExit:
        pass
    except BaseException as exc:                      # noqa: BLE001 -- surfaced in the UI
        STATE["error"] = f"{type(exc).__name__}: {exc}"
        traceback.print_exc()
    finally:
        # Not STATE["running"] = False: after a revive() the main listener
        # lives on in its own thread, and serve_forever's hook tracks it.
        _log("server thread finished")


def start():
    """Start the server (or the Online tunnel -- see configure_tunnel) on a
    daemon thread. Returns immediately."""
    wanted = _wanted_mode()
    alive = STATE["thread"] and STATE["thread"].is_alive()
    if (alive or _main_server() is not None) and not STATE["stopping"] \
            and STATE["mode"] == wanted:
        _log("already running")
        return True
    if alive or STATE["servers"]:
        # Something else is up: the other mode, a stop still in flight, or a
        # stop that left the plain/admin listeners behind. Take it all down
        # and wait, so this start can bind the same ports.
        STATE["stopping"] = True
        _shutdown_all()
        if alive:
            STATE["thread"].join(5)

    if not STATE["installed"]:
        _install_env()
        _install_stdio()
        _install_binary_modules()
        _install_paths()
        _install_datadir()
        _install_server_handle()
        threading.Thread(target=_watchdog, daemon=True, name="windstock-watchdog").start()
        STATE["installed"] = True

    STATE["error"] = None
    STATE["stopping"] = False
    STATE["mode"] = wanted
    STATE["port"] = int(os.environ.get("PORT", "8443"))
    thread = threading.Thread(target=_run, name="windstock-server", daemon=True)
    STATE["thread"] = thread
    thread.start()
    return True


def _shutdown_all():
    for srv in list(STATE["servers"]):
        try:
            srv.shutdown()
            srv.server_close()
        except Exception:                                  # noqa: BLE001
            pass


def stop():
    """Stop every listener -- game, plain HTTP and editor -- so start() can
    bind them all again."""
    STATE["stopping"] = True
    if not STATE["servers"]:
        STATE["running"] = False
        return False
    # shutdown() blocks until serve_forever() returns, and must not be called
    # from the serving thread.
    threading.Thread(target=_shutdown_all, daemon=True).start()
    return True


def status():
    return {
        "running": bool(STATE["running"] and _main_server() is not None),
        "port": STATE["port"],
        "admin_port": STATE["admin_port"],
        "error": STATE["error"],
        "mode": STATE["mode"],
    }


def status_json():
    import json
    return json.dumps(status())
