#!/usr/bin/env python3
"""
Single-device webrtc-operator shim for cuttlefish.

Replaces the upstream `webrtc_operator` daemon for the single-instance,
single-container-per-host policy (see memory:cf-deployment-policy-prototype).
Bridges two transports on the device side and one on the browser side:

    browser  <--HTTPS+WS:8443-->  [this shim]  <--WS:/register_device-->  webRTC   (AOSP)
                                              <--SOCK_SEQPACKET-------->  webRTC   (cf)

AOSP-built launch_cvd opens the WebSocket at /register_device. cf-built
launch_cvd connects to a SOCK_SEQPACKET Unix socket whose path it gets via
--webrtc_sig_server_addr (default /run/cuttlefish/operator). The shim
listens on whichever transports are configured and accepts the first device
that connects via either; subsequent device connections replace the prior
one (single-device policy).

Both transports speak the same JSON envelope vocabulary defined in
host/frontend/webrtc_operator/constants/signaling_constants.h. The two
sides use different envelope wrappings; the shim rewrites between them.

Browser endpoints:
  GET /                       -- static HTML (auto-redirects to ?deviceId=)
  GET /devices/{id}/files/...  -- static client assets
  GET /{name}.{html|css|js|png|svg|ico}  -- static
  GET /connect_client         -- WebSocket: browser signaling channel

Device endpoints:
  GET /register_device        -- WebSocket: AOSP webRTC binary registers + signals
  unix socket (--operator-socket PATH)  -- SOCK_SEQPACKET: cf webRTC binary

Message types (browser <--> shim <--> device, all JSON):
  device --> shim
    {message_type:"register",  device_id, device_port, device_info}
    {message_type:"forward",   client_id, payload}
  shim --> device
    {message_type:"config",    ice_servers:[...]}                     # after register
    {message_type:"client_msg", client_id, payload}                   # from browser
    {message_type:"client_disconnected", client_id}
  browser --> shim
    {message_type:"connect",  device_id}
    {message_type:"forward",  payload}
  shim --> browser
    {message_type:"config",    ice_servers:[...]}                     # before connect
    {message_type:"device_info", device_info}
    {message_type:"device_msg", payload}

ICE servers are read from the CF_ICE_SERVERS_JSON env var at startup
(JSON-encoded array) and handed to both sides.

Usage:
    operator_shim.py [--listen-port N] [--client-dir DIR] [--cert-dir DIR]
                     [--bind ADDR] [--operator-socket PATH] [--verbose]
"""

import argparse
import asyncio
import json
import logging
import os
import socket
import ssl
import subprocess
import sys
from pathlib import Path

import aiohttp
from aiohttp import web

log = logging.getLogger("operator-shim")

# Field/type constants, mirroring signaling_constants.h
F_TYPE = "message_type"
F_DEVICE_INFO = "device_info"
F_DEVICE_ID = "device_id"
F_CLIENT_ID = "client_id"
F_PAYLOAD = "payload"
F_ICE_SERVERS = "ice_servers"
F_DEVICE_PORT = "device_port"

T_REGISTER = "register"
T_CONFIG = "config"
T_CONNECT = "connect"
T_FORWARD = "forward"
T_CLIENT_MSG = "client_msg"
T_DEVICE_MSG = "device_msg"
T_CLIENT_DISCONNECTED = "client_disconnected"
T_DEVICE_INFO = "device_info"

DEFAULT_LISTEN_PORT = 8443
DEFAULT_CLIENT_DIR = "/usr/share/webrtc/assets"
DEFAULT_CERT_DIR = "/usr/share/webrtc/certs"
DEFAULT_OPERATOR_SOCK = "/run/cuttlefish/operator"

# A fresh client_id per browser session. Reusing 1 across reconnects makes
# the device-side streamer reuse a stale ClientHandler (per
# streamer.cpp HandleClientMessage), which leaves new SDP offers unanswered.
_next_client_id = 1

def _alloc_client_id() -> int:
    global _next_client_id
    cid = _next_client_id
    _next_client_id += 1
    return cid


def load_ice_servers_from_env() -> list:
    raw = os.environ.get("CF_ICE_SERVERS_JSON", "")
    if not raw:
        return []
    try:
        ice = json.loads(raw)
        if not isinstance(ice, list):
            log.warning("CF_ICE_SERVERS_JSON is not a JSON array; ignoring")
            return []
        return ice
    except json.JSONDecodeError:
        log.warning("CF_ICE_SERVERS_JSON is not valid JSON; ignoring")
        return []


# ---------------------------------------------------------------------------
# Self-signed cert.  Generated once into /usr/share/webrtc/certs/ if absent.
# ---------------------------------------------------------------------------

def ensure_cert(cert_dir: Path) -> tuple[Path, Path]:
    cert = cert_dir / "server.crt"
    key = cert_dir / "server.key"
    if cert.exists() and key.exists():
        log.info("Reusing TLS material at %s", cert_dir)
        return cert, key
    cert_dir.mkdir(parents=True, exist_ok=True)
    log.info("Generating self-signed cert at %s", cert_dir)
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-days", "3650",
            "-subj", "/CN=cuttlefish-operator-shim",
            "-keyout", str(key),
            "-out", str(cert),
        ],
        check=True,
    )
    return cert, key


# ---------------------------------------------------------------------------
# Device side.  Two parallel implementations:
#   - WSDeviceConnection:    AOSP's webRTC, over the /register_device WS
#   - UnixDeviceConnection:  cf's webRTC, over a SOCK_SEQPACKET unix socket
# Both expose the same public interface so signaling_ws() doesn't care which.
# ---------------------------------------------------------------------------

def _rewrite_candidate(orig: str, new_ip: str, ip_index: int) -> str | None:
    """Rewrite a single 'candidate:...' string (no 'a=' prefix) to point at
    new_ip while preserving component, protocol, port, etc. Only UDP host
    candidates are rewritten; returns None otherwise (TCP host candidates
    would also be cloned but we don't forward a TCP port range, so the
    clone could never form a pair). The foundation is suffixed with
    'x<ip_index>' so multi-IP clones don't share a foundation, which
    could otherwise let an RFC-strict ICE stack dedupe them."""
    if not orig.startswith("candidate:"):
        return None
    parts = orig[len("candidate:"):].split(" ")
    # parts: foundation component proto priority address port "typ" type [...]
    if len(parts) < 8 or parts[6] != "typ" or parts[7] != "host":
        return None
    if parts[2].lower() != "udp":
        return None
    parts[0] = parts[0] + f"x{ip_index}"
    parts[4] = new_ip
    return "candidate:" + " ".join(parts)


def _inject_into_sdp(sdp: str, extra_ips: list[str]) -> str:
    """For every 'a=candidate:... typ host' line, append cloned lines with
    the same port/component but the override IP. Preserve original line
    separators."""
    sep = "\r\n" if "\r\n" in sdp else "\n"
    out: list[str] = []
    for line in sdp.split(sep):
        out.append(line)
        if line.startswith("a=candidate:"):
            for i, ip in enumerate(extra_ips):
                alt = _rewrite_candidate(line[2:], ip, i)
                if alt is not None:
                    out.append("a=" + alt)
    return sep.join(out)


def _process_device_payload(payload: dict, extra_ips: list[str]) -> list[dict]:
    """Return [payload] for irrelevant payloads; or [mutated_payload] when
    SDP carries a=candidate lines; or [original, clone1, clone2...] when the
    payload is a single trickle ICE candidate."""
    if not extra_ips or not isinstance(payload, dict):
        return [payload]

    # SDP offer/answer with embedded candidate lines.
    sdp = payload.get("sdp")
    if isinstance(sdp, str) and "a=candidate:" in sdp:
        new = dict(payload)
        new["sdp"] = _inject_into_sdp(sdp, extra_ips)
        return [new]

    # Trickle ICE: payload may carry the candidate string directly or
    # nested under "candidate": {candidate, sdpMid, sdpMLineIndex}.
    cand = payload.get("candidate")
    if isinstance(cand, str) and cand.startswith("candidate:"):
        result = [payload]
        for i, ip in enumerate(extra_ips):
            alt = _rewrite_candidate(cand, ip, i)
            if alt is not None:
                clone = dict(payload)
                clone["candidate"] = alt
                result.append(clone)
        return result

    if isinstance(cand, dict) and isinstance(cand.get("candidate"), str) \
            and cand["candidate"].startswith("candidate:"):
        result = [payload]
        for i, ip in enumerate(extra_ips):
            alt = _rewrite_candidate(cand["candidate"], ip, i)
            if alt is not None:
                clone = dict(payload)
                inner = dict(cand)
                inner["candidate"] = alt
                clone["candidate"] = inner
                result.append(clone)
        return result

    return [payload]


class _DeviceBase:
    """Shared logic: registration/forwarding state machine and the
    per-browser inbox bookkeeping.  Subclasses provide send() and close()."""

    def __init__(self, ice_servers: list, extra_host_ips: list[str]) -> None:
        self.ice_servers = ice_servers
        self.extra_host_ips = extra_host_ips
        self.device_info: dict | None = None
        self.device_id: str | None = None
        # client_id -> Queue of payloads, populated from the device's
        # {forward, client_id, payload} envelopes by the reader loop.
        self._inboxes: dict[int, asyncio.Queue[dict]] = {}

    async def send(self, msg: dict) -> None:
        raise NotImplementedError

    async def close(self) -> None:
        raise NotImplementedError

    @property
    def is_closed(self) -> bool:
        raise NotImplementedError

    async def send_client_msg(self, client_id: int, payload: dict) -> None:
        await self.send({
            F_TYPE: T_CLIENT_MSG,
            F_CLIENT_ID: client_id,
            F_PAYLOAD: payload,
        })

    async def notify_client_disconnected(self, client_id: int) -> None:
        try:
            await self.send({
                F_TYPE: T_CLIENT_DISCONNECTED,
                F_CLIENT_ID: client_id,
            })
        except (ConnectionError, OSError, RuntimeError):
            pass

    def register_browser(self, client_id: int) -> asyncio.Queue:
        q: asyncio.Queue[dict] = asyncio.Queue()
        self._inboxes[client_id] = q
        return q

    def unregister_browser(self, client_id: int) -> None:
        self._inboxes.pop(client_id, None)

    async def _on_device_message(self, msg: dict) -> None:
        """Handle one parsed JSON envelope from the device."""
        mtype = msg.get(F_TYPE)
        log.debug("device -> %s", mtype)
        if mtype == T_REGISTER:
            self.device_info = msg.get(F_DEVICE_INFO, {})
            self.device_id = msg.get(F_DEVICE_ID)
            log.info("Device registered: id=%s", self.device_id)
            await self.send({
                F_TYPE: T_CONFIG,
                F_ICE_SERVERS: self.ice_servers,
            })
        elif mtype == T_FORWARD:
            # Route by client_id so concurrent browsers don't steal each
            # other's SDP/ICE messages.
            cid = msg.get(F_CLIENT_ID)
            payload = msg.get(F_PAYLOAD, {})
            q = self._inboxes.get(cid)
            if q is None:
                log.warning(
                    "device forward for unknown client_id=%r, dropping", cid)
            else:
                for p in _process_device_payload(payload, self.extra_host_ips):
                    await q.put(p)
        else:
            log.warning("Unexpected device message_type=%r, dropping", mtype)


class WSDeviceConnection(_DeviceBase):
    """Device reached over an aiohttp WebSocket opened to /register_device.
    Connection lifecycle is the WebSocket's lifecycle."""

    def __init__(self, ws: web.WebSocketResponse, ice_servers: list,
                 extra_host_ips: list[str]) -> None:
        super().__init__(ice_servers, extra_host_ips)
        self.ws = ws

    async def send(self, msg: dict) -> None:
        await self.ws.send_json(msg)

    async def close(self) -> None:
        if not self.ws.closed:
            await self.ws.close()

    @property
    def is_closed(self) -> bool:
        return self.ws.closed

    async def run(self) -> None:
        """Read frames from the device until the WS closes."""
        async for raw in self.ws:
            if raw.type != aiohttp.WSMsgType.TEXT:
                continue
            try:
                msg = json.loads(raw.data)
            except json.JSONDecodeError:
                log.exception("Bad JSON from device: %r", raw.data[:200])
                continue
            await self._on_device_message(msg)


class UnixDeviceConnection(_DeviceBase):
    """Device reached over a SOCK_SEQPACKET unix socket.  Each send() emits
    exactly one whole message; reads receive one whole message at a time."""

    def __init__(self, sock: socket.socket, ice_servers: list,
                 extra_host_ips: list[str]) -> None:
        super().__init__(ice_servers, extra_host_ips)
        self.sock = sock
        self.sock.setblocking(False)
        self._closed = False

    async def send(self, msg: dict) -> None:
        if self._closed:
            return
        data = json.dumps(msg).encode()
        loop = asyncio.get_running_loop()
        await loop.sock_sendall(self.sock, data)

    async def close(self) -> None:
        if not self._closed:
            self._closed = True
            try:
                self.sock.close()
            except OSError:
                pass

    @property
    def is_closed(self) -> bool:
        return self._closed

    async def run(self) -> None:
        """Read packets from the device socket until close or EOF."""
        loop = asyncio.get_running_loop()
        try:
            while True:
                try:
                    data = await loop.sock_recv(self.sock, 1 << 16)
                except OSError as e:
                    log.warning("Device socket error: %s", e)
                    return
                if not data:
                    log.info("Device closed connection")
                    return
                try:
                    msg = json.loads(data)
                except json.JSONDecodeError:
                    log.exception("Bad JSON from device: %r", data[:200])
                    continue
                await self._on_device_message(msg)
        finally:
            await self.close()


# ---------------------------------------------------------------------------
# Active-device tracking.  Shared by both transports; a connect on either
# transport replaces the prior device (single-device policy).
# ---------------------------------------------------------------------------

async def _install_device(app: web.Application, device: _DeviceBase) -> None:
    prior: _DeviceBase | None = app["device"]
    app["device"] = device
    if prior is not None and not prior.is_closed and prior is not device:
        log.info("Replacing prior device connection")
        await prior.close()


async def _retire_device(app: web.Application, device: _DeviceBase) -> None:
    if app["device"] is device:
        app["device"] = None


# ---------------------------------------------------------------------------
# /register_device endpoint (AOSP-style WS transport).
# ---------------------------------------------------------------------------

async def register_device_ws(req: web.Request) -> web.WebSocketResponse:
    """Single-device policy: at most one active device.  Existing device is
    replaced on each new registration."""
    app = req.app
    ws = web.WebSocketResponse()
    await ws.prepare(req)
    device = WSDeviceConnection(
        ws, app["ice_servers"], app["extra_host_ips"])
    await _install_device(app, device)
    try:
        await device.run()
    finally:
        await _retire_device(app, device)
        log.info("Device WebSocket closed")
    return ws


# ---------------------------------------------------------------------------
# Unix socket listener (cf-style SOCK_SEQPACKET transport).
# Long-running accept loop; each accepted connection installs a new device.
# ---------------------------------------------------------------------------

async def serve_operator_socket(app: web.Application, path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    srv.setblocking(False)
    srv.bind(path)
    os.chmod(path, 0o666)
    srv.listen(1)
    log.info("Listening for cf-style device on %s", path)
    loop = asyncio.get_running_loop()
    while True:
        conn, _ = await loop.sock_accept(srv)
        log.info("cf device connected on %s", path)
        device = UnixDeviceConnection(
            conn, app["ice_servers"], app["extra_host_ips"])
        await _install_device(app, device)
        try:
            await device.run()
        except Exception:
            log.exception("Unix device loop crashed")
        finally:
            await _retire_device(app, device)
            log.info("cf device disconnected")


# ---------------------------------------------------------------------------
# Browser side.
# ---------------------------------------------------------------------------

async def serve_client_html(req: web.Request):
    """GET / : if URL has no ?deviceId=, redirect to one that does (so users
    don't have to type it). If no device is registered yet, serve a small
    holding page that refreshes itself."""
    device: _DeviceBase | None = req.app["device"]
    if "deviceId" not in req.query:
        if device is not None and device.device_id:
            raise web.HTTPFound(f"/?deviceId={device.device_id}")
        return web.Response(
            status=503,
            content_type="text/html",
            text=("<html><head><meta http-equiv=refresh content=2>"
                  "<title>cuttlefish</title></head>"
                  "<body><p>Waiting for cuttlefish device to register"
                  " ...</p></body></html>"),
        )
    return web.FileResponse(req.app["client_dir"] / "client.html")


async def serve_device_file(req: web.Request) -> web.FileResponse:
    rel = req.match_info.get("path", "") or "client.html"
    target: Path = req.app["client_dir"] / rel
    if not target.is_file():
        raise web.HTTPNotFound()
    return web.FileResponse(target)


async def signaling_ws(req: web.Request):
    device: _DeviceBase | None = req.app["device"]
    if device is None:
        return web.Response(status=503, text="device not registered yet")

    ws = web.WebSocketResponse()
    await ws.prepare(req)
    client_id = _alloc_client_id()
    inbox = device.register_browser(client_id)
    log.info("Browser connected (client_id=%d), bridging signaling", client_id)

    await ws.send_json({
        F_TYPE: T_CONFIG,
        F_ICE_SERVERS: req.app["ice_servers"],
    })

    async def browser_to_device() -> None:
        async for raw in ws:
            if raw.type != aiohttp.WSMsgType.TEXT:
                continue
            try:
                msg = json.loads(raw.data)
            except json.JSONDecodeError:
                log.exception("Bad JSON from browser")
                continue
            mtype = msg.get(F_TYPE)
            log.debug("browser -> %s", mtype)

            if mtype == T_CONNECT:
                if device.device_info is None:
                    await ws.send_json({"error": "device not registered"})
                    continue
                await ws.send_json({
                    F_TYPE: T_DEVICE_INFO,
                    F_DEVICE_INFO: device.device_info,
                })
            elif mtype == T_FORWARD:
                payload = msg.get(F_PAYLOAD, {})
                await device.send_client_msg(client_id, payload)
            else:
                log.warning("Unexpected browser message_type=%r, dropping", mtype)

    async def device_to_browser() -> None:
        while True:
            payload = await inbox.get()
            await ws.send_json({F_TYPE: T_DEVICE_MSG, F_PAYLOAD: payload})

    bt = asyncio.create_task(browser_to_device())
    db = asyncio.create_task(device_to_browser())
    try:
        _, pending = await asyncio.wait(
            {bt, db}, return_when=asyncio.FIRST_COMPLETED)
        for t in pending:
            t.cancel()
    finally:
        device.unregister_browser(client_id)
        await device.notify_client_disconnected(client_id)
        log.info("Browser disconnected (client_id=%d)", client_id)
    return ws


# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

async def amain(args: argparse.Namespace) -> None:
    cert, key = ensure_cert(Path(args.cert_dir))
    ssl_ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ssl_ctx.load_cert_chain(cert, key)

    ice_servers = load_ice_servers_from_env()
    if ice_servers:
        log.info("Loaded %d ice_servers from CF_ICE_SERVERS_JSON", len(ice_servers))
    else:
        log.info("No CF_ICE_SERVERS_JSON; serving empty ice_servers list")

    extra_host_ips = list(args.extra_host_ip or [])
    if extra_host_ips:
        log.info("Will inject extra host candidates at: %s",
                 ", ".join(extra_host_ips))

    app = web.Application()
    app["device"] = None
    app["client_dir"] = Path(args.client_dir)
    app["ice_servers"] = ice_servers
    app["extra_host_ips"] = extra_host_ips

    app.router.add_get("/register_device", register_device_ws)
    app.router.add_get("/connect_client", signaling_ws)
    client_dir = Path(args.client_dir)
    if client_dir.is_dir():
        app.router.add_get("/", serve_client_html)
        app.router.add_get(r"/devices/{id}/files/{path:.*}", serve_device_file)
        app.router.add_get(r"/{path:[^/]+\.(html|css|js|png|svg|ico)}",
                           serve_device_file)
        js_dir = client_dir / "js"
        if js_dir.is_dir():
            app.router.add_static("/js", path=js_dir, show_index=False)
    else:
        log.warning("client-dir %s missing -- HTTPS will only serve "
                    "the WebSocket endpoints", client_dir)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, args.bind, args.listen_port, ssl_context=ssl_ctx)
    await site.start()
    log.info("HTTPS on %s:%d, asset dir=%s",
             args.bind, args.listen_port, args.client_dir)

    bg_tasks: list[asyncio.Task] = []
    if args.operator_socket:
        bg_tasks.append(asyncio.create_task(
            serve_operator_socket(app, args.operator_socket)))

    # Run forever; transports drive device lifecycle.
    if bg_tasks:
        # Surface accept-loop crashes rather than silently lingering.
        done, pending = await asyncio.wait(
            bg_tasks, return_when=asyncio.FIRST_EXCEPTION)
        for t in done:
            exc = t.exception()
            if exc:
                raise exc
    else:
        await asyncio.Event().wait()


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--listen-port", type=int, default=DEFAULT_LISTEN_PORT)
    ap.add_argument("--client-dir", default=DEFAULT_CLIENT_DIR)
    ap.add_argument("--cert-dir", default=DEFAULT_CERT_DIR)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--operator-socket",
                    default="",
                    help="cf-style SOCK_SEQPACKET path; empty disables "
                         "the unix-socket device transport "
                         f"(typical: {DEFAULT_OPERATOR_SOCK})")
    ap.add_argument("--extra-host-ip", action="append", default=[],
                    metavar="IP",
                    help="For every host ICE candidate the device advertises, "
                         "emit a parallel host candidate with this address "
                         "(same port). Use when the container is behind NAT "
                         "and clients reach the host via a side channel "
                         "(e.g. tailscale). Repeatable.")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    try:
        asyncio.run(amain(args))
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
