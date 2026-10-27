# Routing

All routing lives in [envoy/envoy.yaml](../envoy/envoy.yaml) under the single listener's `HttpConnectionManager.route_config`.

## How a request is matched

1. **Virtual host:** the `Host`/`:authority` header, with any port stripped (`strip_any_host_port: true`), is compared to each virtual host's `domains`. Exact names beat wildcards. If no virtual host matches, Envoy returns **404** with flag `NR`.
2. **Route:** the virtual host's `routes` are tried **in order, and the first match wins**. If none match, the result is **404** with flag `NR`.
3. **Cluster:** the route's `cluster` picks the backend, and DNS resolves its endpoint.

Because order matters, list more specific routes before general ones, and put any catch-all `prefix: /` last. Gateway API sorts rules by specificity automatically; native Envoy does not.

## Match types used

| Envoy match | Matches | Gateway API equivalent |
|---|---|---|
| `path: /` | exactly `/` (query string ignored) | `path.type: Exact` |
| `path_separated_prefix: /api` | `/api`, `/api/`, `/api/x`, but **not** `/apix` | `path.type: PathPrefix` |
| `prefix: /` | everything | `PathPrefix: /` |

Avoid a plain `prefix: /api` for application routes, because it also matches `/apix` and `/api-docs`. That differs from Gateway API and so from production. `path_separated_prefix` must not end in `/`; use `prefix: /` for the root.

## Rewriting

`app-two-api-rewrite` replaces the `/api` prefix with `/anything` (httpbin's echo endpoint, so the response shows the rewritten URL):

```yaml
match: { path_separated_prefix: /api }
route: { cluster: app_two, timeout: 15s, prefix_rewrite: /anything }
```

| Request path | Upstream path |
|---|---|
| `/api` | `/anything` |
| `/api/items?page=2` | `/anything/items?page=2` (query preserved) |
| `/apix` | no match → 404 |

This matches Gateway API `URLRewrite` with `ReplacePrefixMatch: /anything`.

**Special case, stripping the prefix to `/`:** `prefix_rewrite: /` would turn `/api/items` into `//items`. To get Gateway API's `ReplacePrefixMatch: /` result (`/api` → `/`, `/api/items` → `/items`), use a regex instead:

```yaml
regex_rewrite:
  pattern: { regex: "^/api/*" }
  substitution: /
```

(This variant was tested in an earlier version of this project.)

Only add a rewrite when the backend really expects a different path; most routes forward paths unchanged.

## Adding routes

The patterns below go inside a virtual host's `routes:`. Add only what you need.

```yaml
# Exact path
- name: myapp-health
  match: { path: /healthz }
  route: { cluster: myapp_web, timeout: 2s }

# Prefix to a different backend (no rewrite)
- name: myapp-api
  match: { path_separated_prefix: /api }
  route: { cluster: myapp_api, timeout: 30s }

# Match on a header (Gateway API: matches[].headers)
- name: myapp-canary
  match:
    prefix: /
    headers:
      - name: x-canary
        string_match: { exact: "true" }
  route: { cluster: myapp_web_canary }

# Redirect (Gateway API: RequestRedirect filter)
- name: myapp-old-docs
  match: { path_separated_prefix: /old-docs }
  redirect: { path_redirect: /docs, response_code: MOVED_PERMANENTLY }

# Fixed response (no backend)
- name: myapp-blocked
  match: { path_separated_prefix: /internal }
  direct_response: { status: 404 }
```

To add a whole new hostname, use `./scripts/add-route.sh` or follow the manual steps in [README: Route to your app](../README.md#route-to-your-app). Then extend its routes with the patterns above. Always run `./scripts/validate.sh` afterwards. Envoy rejects unknown clusters, duplicate names and duplicate domains at load time.

## Unknown hosts and paths

Unmatched hosts and unmatched paths get Envoy's native **404 with an empty body**. The access log line shows `flags=NR details=route_not_found`, and the response carries `x-request-id`.

There is deliberately no custom catch-all virtual host or error page. An unmatched request in production also ends with Envoy's own 404, so local behavior stays close. If you want a friendlier local page, add a last virtual host with `domains: ["*"]` and a `direct_response`, and note that it diverges from production.

## Request headers

| Header | Behavior | Notes |
|---|---|---|
| `Host` / `:authority` | **Preserved**, with port stripped (`app-one.local.test:8080` becomes `app-one.local.test`) | Apps see the public hostname, not the container name. |
| `X-Forwarded-For` | **Appended**: Envoy adds the TCP peer address (`203.0.113.9` becomes `203.0.113.9,172.21.0.1`) | A client-supplied value is kept but **not trusted**. Use the **right-most** entry, or `X-Envoy-External-Address`. |
| `X-Envoy-External-Address` | **Set** to the trusted client address (the TCP peer). Any client value is replaced. | Envoy-specific. |
| `X-Forwarded-Proto` | **Overwritten** with the real downstream scheme (`http` today) | A client claiming `https` is ignored. |
| `X-Real-IP` | **Not set and not stripped**: passed through unchanged | Client-controlled. Apps must not trust it. See below. |
| `X-Request-Id` | **Generated** if absent, forwarded upstream and **returned to the client** | Use it to find the access-log line. A client-sent ID is also kept, so don't use it for security. |
| other `x-envoy-*` from the client | **Stripped**, and `x-envoy-internal` is never set | `internal_address_config` lists only `127.0.0.1/32`. **Caution:** an empty `cidr_ranges: []` does not mean "none": Envoy then treats every RFC1918 address (including Docker's 172.x networks) as internal and trusts client `x-envoy-*` headers. The smoke test covers this case. |
| `x-envoy-upstream-service-time`, `x-envoy-expected-rq-timeout-ms`, `x-envoy-original-path` | **Not added** (`suppress_envoy_headers: true`) | Matches Envoy Gateway's default of not adding Envoy headers. |
| `Server` (response) | `envoy` | Envoy default. |
| Other headers | Passed through unchanged (hop-by-hop headers are handled per HTTP spec) | |

All of these were verified against the running proxy by `scripts/smoke-test.sh`, except `X-Real-IP`, which was checked manually.

### Trust boundary

Locally, **Envoy is the edge**: `use_remote_address: true` and `xff_num_trusted_hops: 0`. The only address Envoy trusts is the TCP peer of the connection it accepted. In Docker this peer is the Docker gateway or port-forwarder (for example `172.21.0.1`), **not** your machine's real address. See [production-parity.md](production-parity.md#client-ip).

If another trusted proxy sits in front of Envoy (as an AWS load balancer can in production), set `xff_num_trusted_hops: 1` so Envoy takes the client from the right-most XFF entry written by that proxy. Only do this when every request really arrives through that proxy. Otherwise any client could forge its IP. For a standalone local setup, leave it at 0.

### X-Real-IP

Envoy has no native `X-Real-IP` behavior (it's an nginx convention). No production requirement for it is known, so it isn't implemented. If production adds it and apps rely on it, set it from the trusted address, which also overwrites any client value. This snippet passes validation but is not exercised by the smoke test:

```yaml
# In route_config (applies to all virtual hosts):
request_headers_to_add:
  - header: { key: x-real-ip, value: "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%" }
    append_action: OVERWRITE_IF_EXISTS_OR_ADD
```

## Timeouts

| Setting | Value | Effect |
|---|---|---|
| Cluster `connect_timeout` | 5s | TCP connect to a backend. A stopped container's stale IP fails after 5s (`503 UF connection_timeout`) until DNS refresh removes it, then requests fail immediately (`503 UH`). |
| Route `timeout` | 15s (Envoy default, explicit) | Whole request until the backend's full response. Exceeding it gives `504 UT`. Raise it per route for slow endpoints. |
| `/delay` route `timeout` | 3s | Shows a per-route timeout: `app-two.local.test/delay/1` → 200, `/delay/5` → `504 UT` after 3s (tested). |
| `/ws` route `timeout` / `idle_timeout` | `0s` / 300s | No total limit for long-lived WebSockets, but idle sockets close after 5 min. |
| `request_headers_timeout` | 10s | The client must send complete headers within 10s, otherwise 408. Protects against slow clients. |
| `stream_idle_timeout` | 300s (Envoy default, explicit) | Closes a stream with no activity. |
| DNS refresh | 5s (Envoy default) | How fast new or removed container IPs are picked up. |

No retries are configured. A failure is reported once and stays visible. Gateway API and Envoy Gateway configure retries explicitly (`HTTPRoute` retries, `BackendTrafficPolicy`), so add `retry_policy` to a route only when production does the same for it.

## WebSocket and upgrades

`upgrade_configs: [{upgrade_type: websocket}]` on the connection manager allows WebSocket upgrades on every route. The dedicated `app-one-websocket` route shows the timeout settings a long-lived socket needs. The smoke test checks that a handshake reaches the backend and returns `101`.

## TLS extension point

HTTP works without certificates. HTTPS is intentionally not implemented yet. To add it later:

1. Generate a locally trusted certificate, for example with [mkcert](https://github.com/FiloSottile/mkcert):

   ```bash
   mkcert -install
   mkdir -p envoy/certs
   mkcert -cert-file envoy/certs/local.pem -key-file envoy/certs/local-key.pem \
     app-one.local.test app-two.local.test
   ```

   `envoy/certs/` and `*.pem` are gitignored. **Never commit the private key.** The container runs as uid 101, so the key file must be readable by it (for example `chmod 644` on a dev-only key).

2. Add a second listener (for example `https` on `:10443`) to `envoy.yaml`, with the same `HttpConnectionManager` settings. Put a `transport_socket` on its filter chain, as a sibling of `filters:`. This snippet passes `envoy --mode validate` on v1.40.2 with a test certificate.

   ```yaml
   transport_socket:
     name: envoy.transport_sockets.tls
     typed_config:
       "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
       common_tls_context:
         tls_certificates:
           - certificate_chain: { filename: /etc/envoy/certs/local.pem }
             private_key: { filename: /etc/envoy/certs/local-key.pem }
         alpn_protocols: ["h2", "http/1.1"]
   ```

   Move `route_config` to a YAML anchor, or to RDS, if you don't want to duplicate it.

3. Publish it in `compose.yaml`, for example `"${ENVOY_BIND_ADDRESS:-127.0.0.1}:${ENVOY_HTTPS_PORT:-8443}:10443"`.

4. Only after HTTPS works, optionally redirect HTTP to HTTPS on the HTTP listener's virtual hosts with `require_tls: ALL` or a route `redirect: { https_redirect: true }`, mirroring production's redirect policy. On the TLS listener, `X-Forwarded-Proto` automatically becomes `https`.
