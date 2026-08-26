"""Bonodis client for Python 3.

Two ways in:

1. Any Redis client against RESP2 (--port, default 6379)::

       import redis
       r = redis.Redis(host="127.0.0.1", port=6379, decode_responses=True)
       r.ping()
       r.set("k", "v")
       r.execute_command("EVAL", "return redis.call('GET', KEYS[1])", 1, "k")
       r.execute_command("BRAIN", "HELP")

2. This module: HTTP JSON on --metrics-port (no redis package required)::

       from bonodis import Bonodis
       b = Bonodis(http_port=9090)          # --metrics-port
       b.call("PING")
       b.call("SET", "k", "v")
       b.call("EVAL", "return 1", "0")
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Iterable, Optional, Sequence


class Bonodis:
    def __init__(
        self,
        host: str = "127.0.0.1",
        http_port: int = 9090,
        auth: Optional[str] = None,
        timeout: float = 5.0,
    ) -> None:
        self.host = host
        self.http_port = http_port
        self.auth = auth
        self.timeout = timeout

    def _url(self, path: str) -> str:
        return f"http://{self.host}:{self.http_port}{path}"

    def _post(self, path: str, payload: dict[str, Any]) -> Any:
        if self.auth:
            payload = dict(payload)
            payload["auth"] = self.auth
        data = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.auth:
            headers["X-Bonodis-Auth"] = self.auth
        req = urllib.request.Request(self._url(path), data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as res:
                return json.loads(res.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8")
            try:
                return json.loads(body)
            except json.JSONDecodeError:
                raise RuntimeError(body) from e

    def ping(self) -> Any:
        with urllib.request.urlopen(self._url("/api/ping"), timeout=self.timeout) as res:
            return json.loads(res.read().decode("utf-8"))

    def call(self, *argv: str) -> Any:
        out = self._post("/api", {"argv": [str(a) for a in argv]})
        if isinstance(out, dict) and not out.get("ok", True):
            raise RuntimeError(out.get("error", "command failed"))
        if isinstance(out, dict) and "result" in out:
            return out["result"]
        return out

    def pipeline(self, commands: Iterable[Sequence[str]]) -> Any:
        return self._post("/api/pipeline", {"commands": [list(c) for c in commands]})

    def eval(self, src: str, keys: Sequence[str] = (), args: Sequence[str] = ()) -> Any:
        argv = ["EVAL", src, str(len(keys)), *keys, *args]
        return self.call(*argv)


if __name__ == "__main__":
    b = Bonodis()
    print(b.ping())
    print(b.call("SET", "demo", "1"))
    print(b.call("GET", "demo"))
