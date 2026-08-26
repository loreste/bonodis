/**
 * Bonodis client for Node 18+ / browsers (fetch).
 *
 * RESP2: any Redis client against --port (default 6379)
 *   import { createClient } from "redis";
 *   const r = createClient({ url: "redis://127.0.0.1:6379" });
 *
 * HTTP JSON against --metrics-port (this module, no Redis driver):
 *   import { Bonodis } from "./bonodis.mjs";
 *   const b = new Bonodis({ httpPort: 9090 });
 *   await b.call("PING");
 *   await b.call("SET", "k", "v");
 *   await b.call("EVAL", "return 1", "0");
 */

export class Bonodis {
  constructor({ host = "127.0.0.1", httpPort = 9090, auth = null } = {}) {
    this.host = host;
    this.httpPort = httpPort;
    this.auth = auth;
  }

  url(path) {
    return `http://${this.host}:${this.httpPort}${path}`;
  }

  async post(path, payload) {
    const body = { ...payload };
    const headers = { "Content-Type": "application/json" };
    if (this.auth) {
      body.auth = this.auth;
      headers["X-Bonodis-Auth"] = this.auth;
    }
    const res = await fetch(this.url(path), {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    return res.json();
  }

  async ping() {
    const res = await fetch(this.url("/api/ping"));
    return res.json();
  }

  async call(...argv) {
    const out = await this.post("/api", { argv: argv.map(String) });
    if (out && out.ok === false) {
      throw new Error(out.error || "command failed");
    }
    return out && Object.prototype.hasOwnProperty.call(out, "result") ? out.result : out;
  }

  async pipeline(commands) {
    return this.post("/api/pipeline", { commands });
  }

  async eval(src, keys = [], args = []) {
    return this.call("EVAL", src, String(keys.length), ...keys, ...args);
  }
}
