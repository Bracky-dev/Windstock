"""
The listeners every door of the server is built from, with the limits that
keep one client from taking the whole thing down.

Kept free of game imports on purpose: the launchers' TLS tunnel (tunnel.py)
uses these too, and must not drag protocol.py and friends into memory.

    ThreadingHTTPServer   a ceiling on open connections, in total and per address
    TLSServer             TLS on every connection, handshake off the accept thread
    DualServer            plain HTTP and TLS on one port, decided per connection
"""
import hashlib
import os
import socket
import ssl
import sys
import threading
import time
from http.server import ThreadingHTTPServer as _ThreadingHTTPServer

# The biggest request we will read. The largest honest one is a Help Center
# nomination with its photo (~4 MB of base64); everything the game sends is a
# few KB. Without a cap, one request with a huge Content-Length fills the RAM.
MAX_BODY = 8 * 1024 * 1024
# A connection that says nothing for this long is dropped, so idle or
# deliberately slow clients can't each hold a thread forever.
IDLE_TIMEOUT = 120
HANDSHAKE_TIMEOUT = 15
TLS_HANDSHAKE = 0x16            # first byte of a TLS handshake record


def loopback(ip):
    return ip in ("127.0.0.1", "::1", "::ffff:127.0.0.1")


def tls_context(cert, key, legacy=True):
    """A server-side TLS context for `cert`/`key`.

    legacy=True is for the game's OWN connections: its 2016-era Mono/BoringSSL
    stacks negotiate TLS 1.0 and old suites, and refusing those refuses the
    game. legacy=False (TLS 1.2+, modern suites) is for doors only the
    launchers' tunnel dials."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    try:
        if legacy:
            ctx.minimum_version = ssl.TLSVersion.TLSv1
            # The 2016 game's Mono/BoringSSL offers only RSA key exchange
            # (AES/3DES/RC4). Newer builds (0.67+) send the RPC over the modern
            # NSURLSession/Network.framework stack, which offers ONLY ECDHE/GCM +
            # ChaCha20 and asks for HTTP/2 -- with just the RSA suites above that
            # handshake fails NO_SHARED_CIPHER and the RPC never leaves the phone.
            # Offer both the modern ECDHE-RSA suites (our cert is RSA) and the old
            # RSA ones, so every era of the client shares a cipher.
            ctx.set_ciphers(
                "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:"
                "ECDHE-RSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-SHA:"
                "ECDHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:"
                "AES128-SHA:AES256-SHA:DES-CBC3-SHA:RC4-SHA:RC4-MD5")
            # An HTTP/2-only ClientHello (alpn h2) must fall back to HTTP/1.1, which
            # is all this server speaks; advertising it makes the client downgrade.
            try:
                ctx.set_alpn_protocols(["http/1.1"])
            except (NotImplementedError, AttributeError):
                pass
        else:
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    except (ssl.SSLError, ValueError):
        pass
    return ctx


def fingerprint(pem):
    """SHA-256 of a PEM certificate, as 'AB:CD:...' -- what an operator reads
    out so a player can check they pinned the right server. '' if unreadable."""
    try:
        digest = hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem.strip())).hexdigest().upper()
    except (ValueError, TypeError, AttributeError):
        return ""
    return ":".join(digest[i:i + 2] for i in range(0, len(digest), 2))


class ThreadingHTTPServer(_ThreadingHTTPServer):
    """ThreadingHTTPServer with a ceiling on open connections, in total and per
    address -- every connection is a thread, and nothing else bounds them.
    (ws_boot.py builds its plain listener from server.ThreadingHTTPServer,
    which is this class.)"""
    daemon_threads = True
    MAX_CONNS = 600
    MAX_PER_IP = 64

    def _slots(self):
        if "_conn_lock" not in self.__dict__:
            self.__dict__.setdefault("_conn_count", {})
            self.__dict__.setdefault("_conn_lock", threading.Lock())
        return self._conn_lock, self._conn_count

    def process_request(self, request, client_address):
        ip = client_address[0]
        lock, count = self._slots()
        with lock:
            full = (sum(count.values()) >= self.MAX_CONNS
                    or (count.get(ip, 0) >= self.MAX_PER_IP and not loopback(ip)))
            if not full:
                count[ip] = count.get(ip, 0) + 1
        if full:
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            lock, count = self._slots()
            with lock:
                left = count.get(client_address[0], 1) - 1
                if left > 0:
                    count[client_address[0]] = left
                else:
                    count.pop(client_address[0], None)

    def handle_error(self, request, client_address):
        # A phone dropping its keep-alive connection (app backgrounded, network
        # switch) or going quiet isn't a server error; no traceback for it.
        if isinstance(sys.exc_info()[1], (ConnectionError, TimeoutError,
                                          socket.timeout, ssl.SSLError)):
            if not loopback(client_address[0]):
                print(f"[conn] {client_address[0]}:{client_address[1]} dropped before a request: "
                      f"{sys.exc_info()[1]!r}", flush=True)
            return
        super().handle_error(request, client_address)

    def shutdown_request(self, request):
        # An SSLSocket and the raw one it wraps are the same fd; closing either is fine.
        try:
            super().shutdown_request(request)
        except OSError:
            pass


class TLSServer(ThreadingHTTPServer):
    """Every connection is TLS. Wrap the LISTENING socket with
    `ctx.wrap_socket(sock, server_side=True, do_handshake_on_connect=False)`.

    The handshake runs here, on the connection's own thread and under a
    timeout. It used to run inside accept(), where one client that connected
    and then said nothing stalled the listener for everybody. Failures are
    logged so we can see WHY a client (e.g. native RPC) is rejected -- 'bad
    certificate' => client distrusts our CA; 'unsupported protocol' / 'no shared
    cipher' => TLS-version/cipher mismatch."""
    log = staticmethod(lambda msg: print(msg, flush=True))

    def finish_request(self, request, client_address):
        if isinstance(request, ssl.SSLSocket):
            hello = ""
            try:
                request.settimeout(HANDSHAKE_TIMEOUT)
                hello = describe_client_hello(request)
                request.do_handshake()
                if not loopback(client_address[0]):
                    self.log(f"[tls] handshake ok {request.version()} {request.cipher()[0]}  "
                             f"from {client_address[0]}:{client_address[1]}  {hello}")
            except ssl.SSLError as e:
                self.log(f"[tls] handshake FAILED: {e!r}  from {client_address[0]}  {hello}")
                return
            except OSError:
                return
        t0 = time.monotonic()
        try:
            super().finish_request(request, client_address)
        finally:
            if isinstance(request, ssl.SSLSocket) and not loopback(client_address[0]):
                self.log(f"[conn] {client_address[0]}:{client_address[1]} closed after "
                         f"{time.monotonic() - t0:.1f}s")


def describe_client_hello(sock):
    """'sni=... ver=... alpn=...' from a peeked ClientHello (diagnostics only)."""
    try:
        raw = socket.socket(fileno=os.dup(sock.fileno()))
        try:
            raw.settimeout(HANDSHAKE_TIMEOUT)
            b = raw.recv(4096, socket.MSG_PEEK)
        finally:
            raw.detach() and None
    except OSError:
        return ""
    try:
        if len(b) < 44 or b[0] != TLS_HANDSHAKE or b[5] != 1:
            return f"(not a ClientHello: {b[:8].hex()})"
        p = 9
        legacy = b[p:p + 2].hex(); p += 2 + 32
        p += 1 + b[p]                                   # session id
        n = int.from_bytes(b[p:p + 2], "big"); ciphers = n // 2; p += 2 + n
        p += 1 + b[p]                                   # compression
        end = p + 2 + int.from_bytes(b[p:p + 2], "big"); p += 2
        sni = alpn = vers = ""
        while p + 4 <= end and p + 4 <= len(b):
            t = int.from_bytes(b[p:p + 2], "big"); ln = int.from_bytes(b[p + 2:p + 4], "big")
            body = b[p + 4:p + 4 + ln]
            if t == 0 and len(body) > 5:
                sni = body[5:5 + int.from_bytes(body[3:5], "big")].decode(errors="replace")
            elif t == 16 and len(body) > 3:
                q, out = 2, []
                while q < len(body):
                    out.append(body[q + 1:q + 1 + body[q]].decode(errors="replace")); q += 1 + body[q]
                alpn = ",".join(out)
            elif t == 43 and body:
                vers = ",".join(body[1 + i:3 + i].hex() for i in range(0, body[0], 2))
            p += 4 + ln
        return f"sni={sni or '-'} legacy={legacy} versions={vers or '-'} alpn={alpn or '-'} ciphers={ciphers}"
    except (IndexError, ValueError):
        return f"(unparsed hello {len(b)} B)"


def sniff(sock, timeout=HANDSHAKE_TIMEOUT):
    """'tls', 'plain', or None if the client sent nothing. Leaves the byte unread."""
    sock.settimeout(timeout)
    try:
        first = sock.recv(1, socket.MSG_PEEK)
    finally:
        sock.settimeout(None)
    if not first:
        return None
    return "tls" if first[0] == TLS_HANDSHAKE else "plain"


class DualServer(ThreadingHTTPServer):
    """Plain HTTP and TLS on ONE port, decided per connection by its first
    byte (0x16 opens a TLS handshake).

    The decision runs in finish_request, which ThreadingMixIn calls on the
    connection's own thread -- a slow or silent client never holds up accept().
    Set `tls_ctx` after building it; without one, TLS connections are dropped.
    """
    tls_ctx = None
    counts = None                    # optional {"plain": n, "tls": n}
    log = staticmethod(lambda msg: print(msg, flush=True))

    def finish_request(self, request, client_address):
        try:
            kind = sniff(request)
        except OSError:
            return
        if kind is None:
            return
        if kind == "tls":
            if self.tls_ctx is None:
                return
            try:
                # Under a timeout: a client that opens a handshake and stalls
                # must not hold this thread forever.
                request.settimeout(HANDSHAKE_TIMEOUT)
                request = self.tls_ctx.wrap_socket(request, server_side=True)
            except (ssl.SSLError, OSError) as e:
                self.log(f"TLS handshake from {client_address[0]} failed: {e!r}")
                return
        if self.counts is not None:
            self.counts[kind] = self.counts.get(kind, 0) + 1
        self.RequestHandlerClass(request, client_address, self)
