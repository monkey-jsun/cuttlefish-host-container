#!/usr/bin/env python3
"""
Single-device webrtc-operator shim for cuttlefish on riscv64.

Replaces the full upstream `webrtc_operator` daemon for the case where exactly
one cuttlefish device is running. Bridges:

    browser  <--HTTPS / WebSocket : 8443-->  [this shim]  <--unix SOCK_SEQPACKET-->  webRTC

Listens at /run/cuttlefish/operator (the path the `webRTC` binary connects to by
default -- see CF_DEFAULTS_WEBRTC_SIG_SERVER_ADDR), accepts exactly one device
registration, then serves HTTPS on 8443 for browser clients.

Protocol confirmed against:
  - device side: server_connection.cpp + streamer.cpp + connection_controller.cpp
                 in cuttlefish/host/frontend/webrtc/
  - browser side: server_connector.js in /usr/share/webrtc/assets/js/

The two sides speak different envelope vocabularies; this shim rewrites between
them.  On the unix socket it's SOCK_SEQPACKET (one JSON object per packet, no
framing).  On the WebSocket it's text frames carrying JSON.

UDS  device --> shim
  {message_type: "register",  device_id, device_port, device_info}
  {message_type: "forward",   client_id, payload}            <-- signaling out

UDS  shim --> device
  {message_type: "config",                 ice_servers}      <-- sent right after register
  {message_type: "client_msg",  client_id, payload}          <-- signaling in
  {message_type: "client_disconnected",    client_id}        <-- browser left

WS   browser --> shim
  {message_type: "connect", device_id}                        <-- first message
  {message_type: "forward", payload}                          <-- signaling out

WS   shim --> browser
  {message_type: "config",     ice_servers: [...]}            <-- before connect
  {message_type: "device_info", device_info}                  <-- response to connect
  {message_type: "device_msg", payload}                       <-- signaling in

Rewrite rules:
  browser-forward(payload)  --->  device-client_msg(client_id, payload)
  device-forward(client_id, payload)  --->  browser-device_msg(payload)

Usage:
    operator_shim.py [--operator-socket PATH] [--listen-port N]
                     [--client-dir DIR] [--cert-dir DIR] [--bind ADDR]
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

# --- Field / type constants, mirroring signaling_constants.h ---------------
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
T_CLIENT_POLL = "client_poll"
T_DEVICE_INFO = "device_info"

DEFAULT_OPERATOR_SOCK = "/run/cuttlefish/operator"
DEFAULT_LISTEN_PORT = 8443
DEFAULT_CLIENT_DIR = "/usr/share/webrtc/assets"
DEFAULT_CERT_DIR = "/usr/share/webrtc/certs"

# Single-device shim, but we still increment client_id per browser session.
# If a browser drops mid-handshake and reconnects, reusing client_id=1 makes
# the device-side streamer reuse a half-formed ClientHandler (per
# streamer.cpp HandleClientMessage: "if clients_.count(client_id) == 0
# CreateClientHandler else reuse"), which leaves the new SDP offer with no
# answer.  A fresh id forces a clean ClientHandler each session.
_next_client_id = 1

def _alloc_client_id() -> int:
    global _next_client_id
    cid = _next_client_id
    _next_client_id += 1
    return cid


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
# Device side -- accept exactly one SOCK_SEQPACKET connection from the
# cuttlefish webRTC binary.
# ---------------------------------------------------------------------------

class DeviceConnection:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.sock.setblocking(False)
        self.device_info: dict | None = None
        self.device_id: str | None = None
        # Per-browser inbox: client_id -> Queue of payloads.  The device's
        # {forward, client_id, payload} envelope is split apart in _reader()
        # so each session only sees its own SDP / ICE / etc.
        self._inboxes: dict[int, asyncio.Queue[dict]] = {}
        self._reader_task = asyncio.create_task(self._reader())

    @classmethod
    async def accept_one(cls, path: str) -> "DeviceConnection":
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
        log.info("Listening for device on %s", path)
        loop = asyncio.get_running_loop()
        conn, _ = await loop.sock_accept(srv)
        srv.close()
        log.info("Device connected")
        return cls(conn)

    async def _reader(self) -> None:
        loop = asyncio.get_running_loop()
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
            mtype = msg.get(F_TYPE)
            log.debug("device -> %s", mtype)

            if mtype == T_REGISTER:
                self.device_info = msg.get(F_DEVICE_INFO, {})
                self.device_id = msg.get(F_DEVICE_ID)
                log.info("Device registered: id=%s", self.device_id)
                # Send config back -- empty ICE list works for same-host peering.
                await self.send({F_TYPE: T_CONFIG, F_ICE_SERVERS: []})
            elif mtype == T_FORWARD:
                # Route by client_id so concurrent browsers don't steal each
                # other's SDP/ICE messages.
                cid = msg.get(F_CLIENT_ID)
                payload = msg.get(F_PAYLOAD, {})
                q = self._inboxes.get(cid)
                if q is None:
                    log.warning(
                        "device forward for unknown client_id=%r, dropping",
                        cid)
                else:
                    await q.put(payload)
            else:
                log.warning("Unexpected device message_type=%r, dropping", mtype)

    async def send(self, msg: dict) -> None:
        data = json.dumps(msg).encode()
        loop = asyncio.get_running_loop()
        # SEQPACKET: one send() = one whole message; never partial.
        await loop.sock_sendall(self.sock, data)

    async def send_client_msg(self, client_id: int, payload: dict) -> None:
        """Wrap browser-side payload and deliver to the device."""
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
        except OSError:
            pass

    def register_browser(self, client_id: int) -> asyncio.Queue:
        q: asyncio.Queue[dict] = asyncio.Queue()
        self._inboxes[client_id] = q
        return q

    def unregister_browser(self, client_id: int) -> None:
        self._inboxes.pop(client_id, None)


# ---------------------------------------------------------------------------
# Browser side -- HTTPS server on :8443.  /connect_client is the WebSocket
# endpoint that server_connector.js opens.
# ---------------------------------------------------------------------------

async def serve_client_html(req: web.Request):
    """GET /  -- if the URL has no ?deviceId=, redirect to one that does
    (so users don't have to type it).  If no device is registered yet, serve
    a small holding page that refreshes itself."""
    device: DeviceConnection | None = req.app["device"]
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
    device: DeviceConnection | None = req.app["device"]
    if device is None:
        return web.Response(status=503, text="device not registered yet")

    ws = web.WebSocketResponse()
    await ws.prepare(req)
    client_id = _alloc_client_id()
    inbox = device.register_browser(client_id)
    log.info("Browser connected (client_id=%d), bridging signaling", client_id)

    # Send infraConfig first.  server_connector.js stores this and uses it
    # when constructing the PeerConnection.  Empty ice_servers is fine for
    # same-host peering (browser will fall back to host candidates).
    await ws.send_json({F_TYPE: T_CONFIG, F_ICE_SERVERS: []})

    # Browser will send {message_type: "connect", device_id: X} as its first
    # message.  We answer with device_info from the stored register message.
    # All subsequent browser messages are {message_type: "forward", payload: ...}.

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
                # Browser is asking for a device.  Reply with device_info.
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
        done, pending = await asyncio.wait(
            {bt, db}, return_when=asyncio.FIRST_COMPLETED
        )
        for t in pending:
            t.cancel()
    finally:
        device.unregister_browser(client_id)
        await device.notify_client_disconnected(client_id)
        log.info("Browser disconnected (client_id=%d)", client_id)
    return ws


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def amain(args: argparse.Namespace) -> None:
    cert, key = ensure_cert(Path(args.cert_dir))
    ssl_ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ssl_ctx.load_cert_chain(cert, key)

    # Start HTTPS up-front so the browser can connect even before the device
    # has registered.  Until then signaling_ws() returns 503 "device not
    # registered yet".  Once the device connects, the placeholder swaps in.
    app = web.Application()
    app["device"] = None  # populated once the device connects
    app["client_dir"] = Path(args.client_dir)
    # Routes that match server_connector.js + cvd status_fetcher URLs.
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
                    "/connect_client", client_dir)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, args.bind, args.listen_port, ssl_context=ssl_ctx)
    await site.start()
    log.info("HTTPS on %s:%d, asset dir=%s",
             args.bind, args.listen_port, args.client_dir)

    # Accept the device connection.  Browser-side endpoints stay responsive
    # in the meantime (returning 503 on /connect_client).
    device = await DeviceConnection.accept_one(args.operator_socket)
    app["device"] = device
    log.info("Open https://<host>:%d/?deviceId=%s",
             args.listen_port, device.device_id or "<unknown>")

    # Run until the device disconnects.
    await device._reader_task


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--operator-socket", default=DEFAULT_OPERATOR_SOCK)
    ap.add_argument("--listen-port", type=int, default=DEFAULT_LISTEN_PORT)
    ap.add_argument("--client-dir", default=DEFAULT_CLIENT_DIR)
    ap.add_argument("--cert-dir", default=DEFAULT_CERT_DIR)
    ap.add_argument("--bind", default="0.0.0.0")
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
