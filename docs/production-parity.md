# Production parity

The aim is **functional consistency**: the same logical hostname and path should reach the same application endpoint, with comparable headers and failure codes. Identical infrastructure or configuration formats are not the aim.

Running the same proxy software does **not** make the environments equivalent. Envoy Gateway generates Envoy configuration from Gateway API resources and its own policies. Its defaults differ by release, and production adds an AWS load balancer and Kubernetes networking in front.

The production statements below come from Gateway API semantics and Envoy Gateway's documented defaults. They were **not verified against the production cluster**. Check them against your gateway's actual `Gateway`, `HTTPRoute`, `ClientTrafficPolicy` and `BackendTrafficPolicy` resources. You can also run `egctl config envoy-proxy route|cluster|listener` against the cluster and compare the generated Envoy config with [envoy/envoy.yaml](../envoy/envoy.yaml).

## Comparison

| Concern | Local native Envoy | Production Envoy Gateway on EKS | Parity |
|---|---|---|---|
| Routing configuration | Hand-written native Envoy YAML (listener, virtual hosts, routes, clusters) | Gateway API `Gateway` + `HTTPRoute`, translated to Envoy config by Envoy Gateway | **Different format, same concepts.** Each local route has an `HTTPRoute` equivalent (table below). |
| Proxy data plane | Envoy `v1.40.2`, one container | Envoy fleet managed by Envoy Gateway; its version is pinned by the Envoy Gateway release | Same software; versions may differ. Align `ENVOY_VERSION` if it matters. |
| Host matching | `domains`, port stripped | `HTTPRoute.spec.hostnames` (no port), merged with the `Gateway` listener hostname | **Equivalent** for exact hostnames. Wildcards follow similar but not identical rules. |
| Path matching | `path`, `path_separated_prefix`, `prefix` | `Exact`, `PathPrefix` (segment-aware), `RegularExpression` | **Equivalent** when `path_separated_prefix` is used for `PathPrefix`. |
| Rule precedence | Manual: first match in file order | Automatic by specificity (exact > longest prefix > …, then other tie-breakers) | **Different mechanism.** Keep local routes ordered most-specific first. |
| Path rewrite | `prefix_rewrite` (or `regex_rewrite` when replacing with `/`) | `URLRewrite` filter (`ReplacePrefixMatch` / `ReplaceFullPath`) | **Equivalent results** for the implemented case (`/api` → `/anything`, query preserved). |
| Unknown host or path | Envoy native 404, empty body, flag `NR` | 404 from Envoy for no matching route. The exact body and headers depend on the Envoy Gateway version. | **Same status code.** Don't depend on the body. |
| Service discovery | Docker DNS + `STRICT_DNS`; one IP per container | Kubernetes Services → EndpointSlices delivered by EDS (pod IPs, kube-proxy bypassed) | **Different.** Readiness, rolling updates, per-pod load balancing and topology-aware routing exist only in production. |
| Backend health | None configured; DNS removes stopped containers | Pod readiness through EndpointSlices; optional active/passive health checks (`BackendTrafficPolicy`) | **Different.** A stopped local container causes `503 UF` for up to about 5s, then `503 UH`. |
| External exposure | Docker port publish on `127.0.0.1:8080` | AWS load balancer (typically NLB) → Envoy Service → Envoy pods | **Not reproduced.** |
| TLS | None yet; documented extension point with local certificates | Gateway listener certificates (Secrets / cert-manager / ACM at the load balancer, depending on setup) | **Not reproduced.** Local `X-Forwarded-Proto` is `http`. |
| HTTP→HTTPS redirect | None | Typically configured on the HTTP listener | **Not reproduced** until local TLS is added. |
| Client IP | Docker gateway address (e.g. `172.21.0.1`); see below | Depends on the load balancer type, target mode, proxy protocol and `ClientTrafficPolicy` client-IP detection | **Not reproducible** in Docker Desktop. |
| Forwarding headers | `use_remote_address: true`, 0 trusted hops; XFF appended; XFP overwritten; client `x-envoy-*` stripped (only loopback is "internal") | Envoy Gateway's default client-IP detection is also "Envoy is the edge" unless `ClientTrafficPolicy` sets trusted hops or custom headers | **Comparable by default.** Diverges if production trusts the load balancer's XFF. Mirror that with `xff_num_trusted_hops` locally only behind a real trusted proxy. |
| `x-envoy-*` headers | Suppressed (`suppress_envoy_headers: true`) | Not added by default (`ClientTrafficPolicy` `enableEnvoyHeaders: false`) | **Equivalent** by default. |
| `X-Request-Id` | Generated and returned to the client | Generated; whether it's returned depends on configuration | **Partially.** The local response header is a debugging convenience. |
| WebSocket | Enabled on all routes | Enabled by default in Envoy Gateway | **Equivalent** for basic upgrades. |
| Timeouts | Route 15s, connect 5s, request headers 10s, stream idle 300s | `HTTPRoute.spec.rules[].timeouts`, `BackendTrafficPolicy` / `ClientTrafficPolicy` timeouts, otherwise Envoy Gateway defaults | **Not guaranteed equal.** Local values are explicit and documented. Copy production values route by route where it matters. |
| Retries, rate limits, auth, CORS, compression | Not configured | Possibly configured via `HTTPRoute` filters and Envoy Gateway policies (`BackendTrafficPolicy`, `SecurityPolicy`, `EnvoyExtensionPolicy`) | **Not reproduced.** Add the native equivalent only when local behavior depends on it. |
| Observability | Text access log on stdout; admin through `docker compose exec` | Envoy Gateway telemetry (access-log format, metrics, tracing) as configured | **Different.** Local log fields are chosen for debugging. |
| Admin UIs | Envoy's own admin page only (`scripts/admin.sh`, or a browser via opt-in `compose.admin.yaml`), plus the local routes UI (`routes-ui`), which is not an Envoy Gateway feature | Envoy's admin on each proxy pod, **plus** the Envoy Gateway admin console (control plane: dashboard, `Gateway`/`HTTPRoute` config dump, stats, pprof) | **Partial.** There is no control plane locally, so there's no Envoy Gateway console. |
| Adding or changing routes | Edit `envoy.yaml`, or use `scripts/add-route.sh` / the routes UI; Envoy restarts (about a second, done automatically) | Apply/merge an `HTTPRoute`. Envoy Gateway pushes the new config to Envoy over xDS **without restarting it** | **Different.** Locally, in-flight connections drop on restart. Production updates are live. |
| Scaling, HA, graceful drain | Single container | Multiple replicas, PodDisruptionBudgets, connection draining on rollout | **Not reproduced.** |

## Client IP

What Envoy actually sees locally:

- **Docker Desktop (macOS, Windows):** requests to the published port pass through Docker Desktop's port forwarder. Envoy sees the bridge network's gateway address (for example `172.21.0.1`) for **every** client, including other machines when `ENVOY_BIND_ADDRESS=0.0.0.0`. The real client IP is **not** available. The smoke test records it as the "peer".
- **Docker Engine on Linux:** with the default userland proxy, the result is similar (gateway address). With `"userland-proxy": false` (iptables DNAT), connections from *other* hosts can keep their source IP, but connections from the same host still don't.

Because Envoy is the edge, `X-Forwarded-For` ends with that gateway address and `X-Envoy-External-Address` equals it. Code that logs or rate-limits by client IP will see one address for everybody locally.

To test IP-dependent logic, send `X-Forwarded-For` yourself. Remember that with `xff_num_trusted_hops: 0` Envoy appends to it rather than trusting it, so the app must read the entry its production trust model selects. Making Envoy trust XFF locally (`xff_num_trusted_hops: 1`) lets you simulate a load balancer, but it also lets any local client spoof its IP. Do it only temporarily and deliberately.

In production, the client IP Envoy sees depends on the load balancer. An NLB in instance mode, IP mode, or with proxy protocol, or an ALB adding XFF, each produces a different source address. Envoy Gateway's `ClientTrafficPolicy` (`clientIPDetection`, `enableProxyProtocol`) decides which of these Envoy trusts. None of this can be reproduced in Docker.

## Native routes ↔ HTTPRoute mapping

How the example routes would map onto Gateway API. Hostnames would be the real production names, and backends Kubernetes Services. This is a conceptual sketch, not manifests to apply.

| Native Envoy (this project) | Gateway API equivalent |
|---|---|
| Listener `http` :10000 | `Gateway` listener `protocol: HTTP` (plus an `HTTPS` listener in production) |
| Virtual host `app-one`, `domains: [app-one.local.test]` | `HTTPRoute` *app-one*, `spec.hostnames: [app-one.<prod-domain>]`, `parentRefs: [<gateway>]` |
| Route `app-one-status-prefix`: `path_separated_prefix: /status` → `app_two` | rule: `matches: [{path: {type: PathPrefix, value: /status}}]`, `backendRefs: [{name: app-two, port: 8080}]` |
| Route `app-one-websocket`: `/ws`, `timeout: 0s`, `idle_timeout: 300s` | rule: `PathPrefix /ws` → app-one. Request timeout via `rules[].timeouts.request`; idle timeout via an Envoy Gateway policy (`BackendTrafficPolicy` / `ClientTrafficPolicy`). |
| Route `app-one-default`: `prefix: /` → `app_one` | rule: `PathPrefix /` → `backendRefs: [{name: app-one, port: 8000}]` |
| Virtual host `app-two`, `domains: [app-two.local.test]` | `HTTPRoute` *app-two*, `spec.hostnames: [app-two.<prod-domain>]` |
| Route `app-two-api-rewrite`: `path_separated_prefix: /api` + `prefix_rewrite: /anything` | rule: `PathPrefix /api`, `filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /anything}}}]` |
| Route `app-two-delay`: `path_separated_prefix: /delay`, `timeout: 3s` | rule: `PathPrefix /delay`, `timeouts: {request: 3s}` |
| Route `app-two-root`: `path: /` | rule: `path: {type: Exact, value: /}` |
| No catch-all on `app-two` → 404 | No matching rule → 404 |
| Cluster `app_two` (`STRICT_DNS sample-app-two:8080`) | `backendRefs` → `Service app-two` port 8080 (Envoy Gateway resolves EndpointSlices) |
| Route `timeout: 15s` | `rules[].timeouts.request: 15s` |
| Cluster `connect_timeout: 5s` | `BackendTrafficPolicy.spec.timeout.tcp.connectTimeout` |
| `suppress_envoy_headers: true` | `ClientTrafficPolicy` `headers.enableEnvoyHeaders: false` (default) |
| `use_remote_address: true`, `xff_num_trusted_hops: 0` | `ClientTrafficPolicy` `clientIPDetection` (default behavior unless configured) |

When adding a local route for a real application, start from its production `HTTPRoute`. Translate each rule with this table, order the native routes most-specific first, and copy any non-default timeouts.
