"""Tiny stdlib client for the Device Hub Pro agent (spike). Address and token come from the
environment (DHP_BIND, DHP_TOKEN), never from files in the repo."""
import http.client
import json
import os
import time


class Agent:
    def __init__(self, host=None, token=None, port=8765, timeout=30):
        self.host = host or os.environ["DHP_BIND"]
        self.token = token if token is not None else os.environ.get("DHP_TOKEN", "")
        self.port = port
        self.timeout = timeout
        self.conn = None

    def _connect(self):
        self.conn = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        # NODELAY matters for small request/response ping-pong.
        self.conn.connect()
        import socket
        self.conn.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def request(self, method, path, body=None, headers=None):
        """Returns (status, body_bytes, seconds)."""
        h = {"X-DeviceHubPro-Token": self.token} if self.token is not None else {}
        if headers is not None:
            h = headers
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            h = dict(h, **{"Content-Type": "application/json"})
        t0 = time.perf_counter()
        for attempt in (0, 1):
            try:
                if self.conn is None:
                    self._connect()
                self.conn.request(method, path, body=data, headers=h)
                r = self.conn.getresponse()
                out = r.read()
                break
            except (http.client.HTTPException, OSError):
                self.conn = None
                if attempt:
                    raise
        return r.status, out, time.perf_counter() - t0

    def json(self, method, path, body=None):
        s, b, dt = self.request(method, path, body)
        return s, (json.loads(b) if b and b[:1] in b"{[" else b), dt
