#!/usr/bin/env python3
"""Smoke-test the stealth series in a built chrome, over CDP.

  smoke.py [--headed] <path/to/chrome>

Launches chrome with persona switches and probes a page. Standard library only
(a minimal WebSocket client is inlined), so it runs on a bare runner. Stock
Chromium on Linux fails the platform, userAgent and hardwareConcurrency checks,
so a build without the series (or with its switches not reaching the renderer,
patch 0050) fails. webdriver and plugins already pass on stock headless; they
guard regressions.

--headed runs chrome on the current DISPLAY (e.g. under xvfb-run) and also
checks the WebGL spoof, which reads as empty without a display.

Exit code is the number of failed checks.
"""
import base64
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

PORT = 9444

PROBE = """(() => {
  const gl = document.createElement("canvas").getContext("webgl");
  const dbg = gl && gl.getExtension("WEBGL_debug_renderer_info");
  return {
    webdriver: navigator.webdriver,
    platform: navigator.platform,
    userAgent: navigator.userAgent,
    hardwareConcurrency: navigator.hardwareConcurrency,
    plugins: navigator.plugins.length,
    webglVendor: dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : null,
    webglRenderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : null,
  };
})()"""

GPU_VENDOR = "Google Inc. (Intel)"
GPU_RENDERER = "ANGLE (Intel, Intel(R) UHD Graphics 620 (0x00003EA0) Direct3D11 vs_5_0 ps_5_0, D3D11)"

CHECKS = [
    ("navigator.webdriver is false", lambda r: r["webdriver"] is False),
    ("navigator.platform is Win32", lambda r: r["platform"] == "Win32"),
    ("userAgent claims Windows", lambda r: "Windows NT 10.0; Win64; x64" in r["userAgent"]),
    ("userAgent has no HeadlessChrome", lambda r: "HeadlessChrome" not in r["userAgent"]),
    ("five PDF plugins", lambda r: r["plugins"] == 5),
    ("hardwareConcurrency follows the switch", lambda r: r["hardwareConcurrency"] == 12),
]
HEADED_CHECKS = [
    ("WebGL vendor follows the switch", lambda r: r["webglVendor"] == GPU_VENDOR),
    ("WebGL renderer follows the switch", lambda r: r["webglRenderer"] == GPU_RENDERER),
]


def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("websocket closed")
        buf += chunk
    return buf


class WebSocket:
    """Just enough RFC 6455 for CDP: masked text frames out, whole messages in."""

    def __init__(self, url: str):
        u = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port), timeout=60)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            f"GET {u.path} HTTP/1.1\r\nHost: {u.netloc}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n".encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += recv_exact(self.sock, 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ConnectionError(f"websocket upgrade refused: {head!r}")

    def send(self, text: str) -> None:
        payload = text.encode()
        n = len(payload)
        if n < 126:
            header = struct.pack("!BB", 0x81, 0x80 | n)
        elif n < 1 << 16:
            header = struct.pack("!BBH", 0x81, 0x80 | 126, n)
        else:
            header = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
        mask = os.urandom(4)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def recv(self) -> str:
        message = b""
        while True:
            b0, b1 = recv_exact(self.sock, 2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", recv_exact(self.sock, 2))[0]
            elif n == 127:
                n = struct.unpack("!Q", recv_exact(self.sock, 8))[0]
            message += recv_exact(self.sock, n)
            if b0 & 0x80:
                return message.decode()


def evaluate(base: str, expression: str) -> dict:
    with urllib.request.urlopen(f"{base}/json/list", timeout=10) as r:
        page = next(t for t in json.load(r) if t["type"] == "page")
    # The target's own URL names the browser's address; ours is the one we reached.
    path = urllib.parse.urlparse(page["webSocketDebuggerUrl"]).path
    ws = WebSocket(base.replace("http", "ws", 1) + path)
    ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                        "params": {"expression": expression, "returnByValue": True}}))
    while True:
        msg = json.loads(ws.recv())
        if msg.get("id") == 1:
            return msg["result"]["result"]["value"]


def wait_for_cdp(base: str, proc: subprocess.Popen | None = None) -> None:
    for _ in range(120):
        if proc and proc.poll() is not None:
            raise RuntimeError(f"chrome exited before CDP came up (rc={proc.returncode})")
        try:
            with urllib.request.urlopen(f"{base}/json/version", timeout=2):
                return
        except OSError:
            time.sleep(0.5)
    raise RuntimeError(f"no CDP at {base}")


def launch(chrome: str, headed: bool) -> dict:
    mode = ["--ignore-gpu-blocklist",
            f"--fingerprint-gpu-vendor={GPU_VENDOR}",
            f"--fingerprint-gpu-renderer={GPU_RENDERER}"] if headed else ["--headless=new"]
    with tempfile.TemporaryDirectory() as profile:
        proc = subprocess.Popen(
            [
                chrome,
                *mode,
                # Headed, the first-run flow blocks DevTools from starting.
                "--no-first-run",
                "--no-default-browser-check",
                "--no-sandbox",
                "--disable-dev-shm-usage",
                f"--remote-debugging-port={PORT}",
                f"--user-data-dir={profile}",
                "--fingerprint=42069",
                "--fingerprint-platform=windows",
                "--fingerprint-hardware-concurrency=12",
                "about:blank",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            base = f"http://127.0.0.1:{PORT}"
            wait_for_cdp(base, proc)
            return evaluate(base, PROBE)
        finally:
            # The whole group: renderers left behind would still be writing to
            # the profile while it is deleted.
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()


def main() -> int:
    args = sys.argv[1:]
    headed = args[:1] == ["--headed"]
    if headed:
        args = args[1:]
    if len(args) != 1:
        sys.exit(f"usage: {sys.argv[0]} [--headed] <path/to/chrome>")
    result = launch(args[0], headed)
    print(json.dumps(result, indent=2))

    failed = 0
    for label, check in CHECKS + (HEADED_CHECKS if headed else []):
        ok = check(result)
        failed += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {label}")
    return failed


if __name__ == "__main__":
    sys.exit(main())
