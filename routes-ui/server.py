"""Routes web UI for envoy-local.

Lists every virtual host in envoy/envoy.yaml with its live status, and adds or
removes routes by running scripts/add-route.sh (ADD_ROUTE_MODE=container), the
same script developers run from the terminal. This server holds no routing
logic of its own: validation, rollback and the Envoy restart all live in the
script.

Only requests addressed to 127.0.0.1/localhost are served, and changes must be
JSON requests from this page's own origin, so other websites open in the
browser cannot drive it.
"""

import http.client
import json
import os
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

import yaml

WORKSPACE = "/workspace"
CONFIG = os.path.join(WORKSPACE, "envoy/envoy.yaml")
SCRIPT = os.path.join(WORKSPACE, "scripts/add-route.sh")
ADMIN_SOCKET = "/run/envoy-admin/admin.sock"
LISTEN_PORT = 8090
PUBLIC_PORT = os.environ.get("ROUTES_UI_PORT", str(LISTEN_PORT))
HTTP_PORT = os.environ.get("ENVOY_HTTP_PORT", "8080")
ALLOWED_HOSTS = {f"127.0.0.1:{PUBLIC_PORT}", f"localhost:{PUBLIC_PORT}"}
ALLOWED_ORIGINS = {f"http://{h}" for h in ALLOWED_HOSTS}
MANAGED = re.compile(r"# --- add-route: (\S+) ---")
MATCH_KEYS = ("path", "path_separated_prefix", "prefix", "safe_regex")

# One change at a time: each one rewrites envoy.yaml and restarts Envoy.
change_lock = threading.Lock()


def describe_route(route, clusters):
    match = route.get("match", {})
    kind = next((k for k in MATCH_KEYS if k in match), "match")
    value = match.get(kind, "")
    if kind == "safe_regex":
        value = value.get("regex", "")
    label = {"path": "=", "path_separated_prefix": "prefix", "prefix": "prefix"}.get(kind, kind)
    if "route" in route:
        action = route["route"]
        cluster = action.get("cluster", "?")
        dest = f"{cluster} ({clusters.get(cluster, 'unknown cluster')})"
        if "prefix_rewrite" in action:
            dest += f", rewrite → {action['prefix_rewrite']}"
        if "regex_rewrite" in action:
            dest += f", rewrite → {action['regex_rewrite'].get('substitution')}"
    elif "redirect" in route:
        dest = "redirect"
    elif "direct_response" in route:
        dest = f"fixed response {route['direct_response'].get('status')}"
    else:
        dest = "?"
    return {"path": value if kind in ("prefix", "path_separated_prefix") else None,
            "text": f"{label} {value} → {dest}"}


def load_hosts():
    text = open(CONFIG).read()
    managed = set(MANAGED.findall(text))
    config = yaml.safe_load(text)
    clusters = {}
    for cluster in config["static_resources"].get("clusters", []):
        addresses = [
            "{address}:{port_value}".format(**lb["endpoint"]["address"]["socket_address"])
            for group in cluster.get("load_assignment", {}).get("endpoints", [])
            for lb in group.get("lb_endpoints", [])
        ]
        clusters[cluster["name"]] = ", ".join(addresses)
    hosts = []
    for listener in config["static_resources"].get("listeners", []):
        for chain in listener.get("filter_chains", []):
            for net_filter in chain.get("filters", []):
                route_config = net_filter.get("typed_config", {}).get("route_config", {})
                for vhost in route_config.get("virtual_hosts", []):
                    domains = vhost.get("domains", [])
                    hosts.append({
                        "host": domains[0] if domains else vhost.get("name"),
                        "domains": domains,
                        "routes": [describe_route(r, clusters) for r in vhost.get("routes", [])],
                        "managed": any(d in managed for d in domains),
                    })
    return hosts


def envoy_ready():
    result = subprocess.run(
        ["curl", "-fsS", "--max-time", "2", "--unix-socket", ADMIN_SOCKET, "http://localhost/ready"],
        capture_output=True, text=True)
    return result.stdout.strip() == "LIVE"


def probe(host, path="/"):
    """Status code Envoy returns for GET <path> on this host (what a browser would get)."""
    try:
        conn = http.client.HTTPConnection("envoy", 10000, timeout=6)
        conn.request("GET", path if path.startswith("/") else "/", headers={"Host": host})
        status = conn.getresponse().status
        conn.close()
        return status
    except OSError as err:
        return str(err)


def run_script(*args):
    env = dict(os.environ, ADD_ROUTE_MODE="container")
    result = subprocess.run(["bash", SCRIPT, *args], capture_output=True, text=True,
                            cwd=WORKSPACE, env=env, timeout=120)
    output = (result.stdout + result.stderr).replace("\x1b[33m", "").replace("\x1b[0m", "")
    return result.returncode == 0, output.strip()


class Handler(BaseHTTPRequestHandler):
    server_version = "routes-ui"

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def allowed(self, changing):
        if self.headers.get("Host") not in ALLOWED_HOSTS:
            self.send_json(403, {"error": "use http://127.0.0.1:%s/" % PUBLIC_PORT})
            return False
        if changing:
            origin = self.headers.get("Origin")
            json_body = self.headers.get("Content-Type", "").startswith("application/json")
            if (origin and origin not in ALLOWED_ORIGINS) or not json_body:
                self.send_json(403, {"error": "cross-origin or non-JSON change rejected"})
                return False
        return True

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/healthz":
            return self.send_json(200, {"ok": True})
        if not self.allowed(changing=False):
            return
        if url.path == "/":
            body = PAGE.replace("__HTTP_PORT__", HTTP_PORT).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'")
            self.end_headers()
            self.wfile.write(body)
        elif url.path == "/api/routes":
            try:
                hosts = load_hosts()
            except Exception as err:  # malformed YAML edited by hand, etc.
                return self.send_json(500, {"error": f"cannot read envoy.yaml: {err}"})
            self.send_json(200, {"envoy_ready": envoy_ready(), "http_port": HTTP_PORT, "hosts": hosts})
        elif url.path == "/api/status":
            query = parse_qs(url.query)
            host, path = query.get("host", [""])[0], query.get("path", ["/"])[0]
            self.send_json(200, {"host": host, "path": path, "status": probe(host, path)})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self.allowed(changing=True):
            return
        if urlparse(self.path).path != "/api/routes":
            return self.send_json(404, {"error": "not found"})
        try:
            data = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
            host, kind, port = data["host"].strip(), data["kind"], str(data["port"]).strip()
            target = f"host:{port}" if kind == "host" else f"container:{data['name'].strip()}:{port}"
            path = (data.get("path") or "/").strip()
            rewrite = (data.get("rewrite") or "").strip()
        except (ValueError, KeyError, AttributeError, TypeError):
            return self.send_json(400, {"ok": False, "output": "expected JSON: host, kind (host|container), name, port, path, rewrite"})
        args = [host, target, "--path", path] + (["--rewrite", rewrite] if rewrite else [])
        with change_lock:
            ok, output = run_script(*args)
        self.send_json(200 if ok else 422, {"ok": ok, "output": output})

    def do_DELETE(self):
        if not self.allowed(changing=True):
            return
        url = urlparse(self.path)
        if not url.path.startswith("/api/routes/"):
            return self.send_json(404, {"error": "not found"})
        args = ["--remove", unquote(url.path.rsplit("/", 1)[1])]
        route_path = parse_qs(url.query).get("path", [""])[0]
        if route_path:
            args += ["--path", route_path]
        with change_lock:
            ok, output = run_script(*args)
        self.send_json(200 if ok else 422, {"ok": ok, "output": output})

    def log_message(self, fmt, *args):
        if not self.path.startswith(("/healthz", "/api/status")):
            super().log_message(fmt, *args)


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>envoy-local routes</title>
<style>
  :root { --bg:#f7f7f8; --card:#fff; --text:#1d1d1f; --muted:#6b6b73; --line:#e3e3e8;
          --accent:#3b5bdb; --ok:#2b8a3e; --warn:#c77700; --err:#c92a2a; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#141416; --card:#1d1d21; --text:#ececf1; --muted:#9a9aa5; --line:#2e2e35;
            --accent:#7c94ff; --ok:#51cf66; --warn:#fcc419; --err:#ff6b6b; }
  }
  * { box-sizing: border-box; }
  body { margin:0; font:14px/1.5 system-ui, -apple-system, sans-serif; background:var(--bg); color:var(--text); }
  main { max-width:1100px; margin:0 auto; padding:24px 16px 48px; }
  h1 { font-size:20px; margin:0 0 4px; }
  .sub { color:var(--muted); margin:0 0 20px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:16px; margin-bottom:16px; }
  h2 { font-size:15px; margin:0 0 12px; }
  form { display:flex; flex-wrap:wrap; gap:8px; align-items:end; }
  label { display:flex; flex-direction:column; gap:4px; font-size:12px; color:var(--muted); }
  input, select { font:inherit; padding:7px 9px; border:1px solid var(--line); border-radius:6px; background:var(--bg); color:var(--text); }
  button { font:inherit; padding:7px 14px; border:0; border-radius:6px; background:var(--accent); color:#fff; cursor:pointer; }
  button.secondary { background:transparent; color:var(--accent); border:1px solid var(--line); }
  button.danger { background:transparent; color:var(--err); border:1px solid var(--line); }
  button:disabled { opacity:.5; cursor:wait; }
  pre { background:var(--bg); border:1px solid var(--line); border-radius:6px; padding:10px; white-space:pre-wrap; margin:12px 0 0; font-size:12px; }
  pre.err { border-color:var(--err); }
  .table-wrap { overflow-x:auto; }
  table { width:100%; border-collapse:collapse; }
  th, td { text-align:left; padding:8px; border-top:1px solid var(--line); vertical-align:top; }
  th { font-size:12px; color:var(--muted); font-weight:600; border-top:0; }
  td.routes div { font-family: ui-monospace, Menlo, monospace; font-size:12px; display:flex; gap:8px; align-items:center; padding:2px 0; }
  td.routes .code { min-width:34px; text-align:right; }
  button.x { padding:0 7px; font-size:12px; line-height:18px; }
  .actions { white-space:nowrap; }
  .actions button { margin-left:4px; }
  .badge { display:inline-block; padding:1px 8px; border-radius:999px; font-size:12px; border:1px solid var(--line); }
  .s2 { color:var(--ok); } .s3 { color:var(--accent); } .s4 { color:var(--warn); } .s5, .sx { color:var(--err); }
  .muted { color:var(--muted); }
  code { font-family: ui-monospace, Menlo, monospace; font-size:12px; }
  a { color:var(--accent); }
</style>
</head>
<body>
<main>
  <h1>envoy-local routes</h1>
  <p class="sub">Envoy: <span id="envoy" class="badge">…</span> · listener on port <code>__HTTP_PORT__</code> ·
     changes run <code>scripts/add-route.sh</code> (validate, then restart Envoy)</p>

  <section class="card">
    <h2>Add a route to your app</h2>
    <form id="add">
      <label>Hostname <input name="host" placeholder="myapp.local.test" required pattern="[a-z0-9.-]+" size="24"></label>
      <label>Your app runs
        <select name="kind">
          <option value="host">on my machine / published port</option>
          <option value="container">in a container (shared network)</option>
        </select>
      </label>
      <label id="name-field" hidden>Container name <input name="name" placeholder="myapp-web-1" size="18"></label>
      <label>Port <input name="port" type="number" min="1" max="65535" placeholder="3000" required size="6"></label>
      <label>Path prefix <input name="path" value="/" placeholder="/" pattern="/[A-Za-z0-9._~/-]*" size="12"></label>
      <label>Rewrite prefix to <input name="rewrite" placeholder="(keep path)" pattern="/[A-Za-z0-9._~/-]*" size="12"></label>
      <button type="submit">Add route</button>
    </form>
    <p class="muted" id="hint">Port your app listens on, on your machine (e.g. <code>npm run dev</code> on 3000), or the published container port.</p>
    <p class="muted">Path prefix: <code>/api</code> matches <code>/api</code> and <code>/api/…</code> (not <code>/apix</code>). Rewrite replaces that prefix before forwarding:
       path <code>/api</code> + rewrite <code>/</code> sends <code>/api/items</code> as <code>/items</code>. Add several paths to the same hostname to send each one to a different app;
       the most specific path wins.</p>
    <pre id="output" hidden></pre>
  </section>

  <section class="card">
    <h2>Hostnames <button class="secondary" id="refresh" style="float:right">Refresh</button></h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Hostname</th><th>Status · routes (match → backend), in match order</th><th>Source</th><th></th></tr></thead>
        <tbody id="rows"><tr><td colspan="4" class="muted">Loading…</td></tr></tbody>
      </table>
    </div>
  </section>

  <section class="card">
    <h2>Open in a browser</h2>
    <p class="muted">Hostnames must resolve to 127.0.0.1. Add any missing ones to your hosts file (macOS/Linux):</p>
    <pre id="hosts"></pre>
  </section>
</main>
<script>
const $ = (s) => document.querySelector(s);
const form = $("#add"), output = $("#output");

form.kind.addEventListener("change", () => {
  const container = form.kind.value === "container";
  $("#name-field").hidden = !container;
  form.name.required = container;
  $("#hint").textContent = container
    ? "Container name (docker ps) and the port it listens on inside the container. Envoy must share its network (README: Integrating with an existing app)."
    : "Port your app listens on, on your machine (e.g. npm run dev on 3000), or the published container port.";
});

function show(text, ok) {
  output.hidden = false;
  output.textContent = text;
  output.className = ok ? "" : "err";
}

async function call(method, url, body) {
  const res = await fetch(url, { method, headers: { "Content-Type": "application/json" },
                                 body: body ? JSON.stringify(body) : undefined });
  return res.json();
}

function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}

async function load() {
  const data = await (await fetch("/api/routes")).json();
  const envoy = $("#envoy");
  if (data.error) { show(data.error, false); return; }
  envoy.textContent = data.envoy_ready ? "ready" : "not ready";
  envoy.className = "badge " + (data.envoy_ready ? "s2" : "s5");
  const rows = $("#rows");
  rows.replaceChildren();
  for (const h of data.hosts) {
    const tr = el("tr");
    const name = el("td");
    const link = el("a", h.host);
    link.href = `http://${h.host}:${data.http_port}/`;
    link.target = "_blank";
    name.append(link);
    const routes = el("td", undefined, "routes");
    for (const r of h.routes) {
      const line = el("div");
      const code = el("span", "…", "code muted");
      line.append(code, el("span", r.text));
      if (h.managed && r.path) {
        const x = el("button", "×", "danger x");
        x.title = `Remove route ${r.path}`;
        x.onclick = () => change("DELETE", `/api/routes/${encodeURIComponent(h.host)}?path=${encodeURIComponent(r.path)}`,
                                 undefined, `Remove route ${h.host}${r.path}?`);
        line.append(x);
      }
      routes.append(line);
      const probePath = r.path || "/";
      fetch(`/api/status?host=${encodeURIComponent(h.host)}&path=${encodeURIComponent(probePath)}`)
        .then((res) => res.json()).then((s) => {
          code.textContent = s.status;
          code.className = "code " + (typeof s.status === "number" ? "s" + String(s.status)[0] : "sx");
          code.title = `GET ${probePath}: ` + ({ 404: "no route (or the app returned 404)",
            503: "backend not reachable (not running, or not on a shared network)" }[s.status] || s.status);
        });
    }
    const source = el("td", h.managed ? "add-route" : "envoy.yaml (hand-written)", "muted");
    const actions = el("td", undefined, "actions");
    if (h.managed) {
      const add = el("button", "+ path", "secondary");
      add.onclick = () => { form.host.value = h.host; form.path.value = ""; form.path.focus();
                            form.scrollIntoView({ behavior: "smooth" }); };
      const rm = el("button", "Remove host", "danger");
      rm.onclick = () => change("DELETE", "/api/routes/" + encodeURIComponent(h.host), undefined,
                                `Remove ${h.host} and all its routes?`);
      actions.append(add, rm);
    }
    tr.append(name, routes, source, actions);
    rows.append(tr);
  }
  const names = data.hosts.flatMap((h) => h.domains).filter((d) => !d.includes("*"));
  $("#hosts").textContent = `echo '127.0.0.1 ${names.join(" ")}' | sudo tee -a /etc/hosts`;
}

async function change(method, url, body, question) {
  if (question && !confirm(question + " Envoy restarts (about a second).")) return;
  document.querySelectorAll("button").forEach((b) => (b.disabled = true));
  show("Applying: validating envoy.yaml and restarting Envoy…", true);
  try {
    const r = await call(method, url, body);
    show(r.output || r.error, r.ok);
    return r.ok;
  } catch (err) {
    show(String(err), false);
  } finally {
    document.querySelectorAll("button").forEach((b) => (b.disabled = false));
    load();
  }
}

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const ok = await change("POST", "/api/routes", {
    host: form.host.value, kind: form.kind.value, name: form.name.value, port: form.port.value,
    path: form.path.value || "/", rewrite: form.rewrite.value });
  if (ok) form.reset(), form.kind.dispatchEvent(new Event("change"));
});
$("#refresh").onclick = load;
load();
</script>
</body>
</html>
"""


if __name__ == "__main__":
    print(f"routes-ui listening on :{LISTEN_PORT} (open http://127.0.0.1:{PUBLIC_PORT}/)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
