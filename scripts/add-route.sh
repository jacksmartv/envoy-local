#!/usr/bin/env bash
# Add or remove routes from a hostname to your apps.
#
#   ./scripts/add-route.sh myapp.local.test host:3000
#   ./scripts/add-route.sh myapp.local.test container:myapp-api-1:8080 --path /api --rewrite /
#   ./scripts/add-route.sh --remove myapp.local.test --path /api   # one route
#   ./scripts/add-route.sh --remove myapp.local.test               # the whole hostname
#   ./scripts/add-route.sh --list
#
# Targets:
#   host:PORT             a service running on this machine, or a container
#                         port published to it (reached as host.docker.internal)
#   container:NAME:PORT   a container on a Docker network Envoy is attached to
#                         (see compose.integration.example.yaml): container name
#                         or alias, and the port it listens on *inside* the container
#
# Options:
#   --path PREFIX     path prefix to route (default /). Segment-aware like Gateway
#                     API PathPrefix: /api matches /api and /api/x, not /apix.
#   --rewrite PREFIX  replace the matched prefix before forwarding, like Gateway API
#                     URLRewrite ReplacePrefixMatch: --path /api --rewrite / sends
#                     /api/items as /items. Not allowed with --path /.
#   --no-restart      only edit and validate envoy.yaml
#
# Each hostname gets one virtual host and one cluster per distinct target in
# envoy/envoy.yaml, between "add-route" comment markers, as plain native YAML
# (one line per route). Routes are kept ordered longest prefix first, because
# Envoy uses the first match. After each change the file is validated (restored
# if Envoy rejects it) and Envoy is restarted. If you hand-edit a generated
# block into another shape, the script refuses to modify it rather than guess.
#
# The routes web UI (routes-ui) runs this same script inside its container with
# ADD_ROUTE_MODE=container: it validates with the envoy binary in that image and
# restarts Envoy through the admin socket (Docker brings it back), instead of
# using `docker compose`.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=envoy/envoy.yaml
MODE=${ADD_ROUTE_MODE:-host}
ADMIN_SOCKET=/run/envoy-admin/admin.sock
VH_MARKER='# @add-route:virtual-hosts'
CL_MARKER='# @add-route:clusters'
HOST_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
NAME_RE='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
PATH_RE='^/([A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*)?$'
VH_INDENT='                    '
ROUTE_INDENT='                        '

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "add-route: $*" >&2; exit 1; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*"; }

action=add restart=true host="" target="" path="" rewrite=""
while [ $# -gt 0 ]; do
  case $1 in
    --remove) action=remove ;;
    --list) action=list ;;
    --no-restart) restart=false ;;
    --path) [ $# -ge 2 ] || die "--path needs a value"; path=$2; shift ;;
    --rewrite) [ $# -ge 2 ] || die "--rewrite needs a value"; rewrite=$2; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) if [ -z "$host" ]; then host=$1; elif [ -z "$target" ]; then target=$1; else die "too many arguments"; fi ;;
  esac
  shift
done

grep -qF "$VH_MARKER" "$CONFIG" && grep -qF "$CL_MARKER" "$CONFIG" \
  || die "markers '$VH_MARKER' / '$CL_MARKER' not found in $CONFIG"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$CONFIG" "$tmp/envoy.yaml.bak"

# --- Reading and writing one hostname's generated blocks ----------------------

set_host() {
  host=$1
  start_marker="# --- add-route: $host ---"
  end_marker="# --- end add-route: $host ---"
}

managed() { grep -qF "$start_marker" "$CONFIG"; }

# Splits the host's blocks into: $tmp/routes (one route per line),
# $tmp/clusters (name TAB address TAB port) and $tmp/unexpected (anything else
# in the virtual-host block, i.e. hand edits or the older multi-line format).
read_host() {
  awk -v s="$start_marker" -v e="$end_marker" \
      -v R="$tmp/routes" -v C="$tmp/clusters" -v U="$tmp/unexpected" '
    BEGIN { printf "" > R; printf "" > C; printf "" > U }
    index($0, s) { block++; inside = 1; next }
    index($0, e) { inside = 0; next }
    !inside { next }
    block == 1 {
      line = $0; sub(/^ +/, "", line)
      if (line ~ /^- \{ name: "/) print line > R
      else if (line !~ /^- name: / && line !~ /^domains: / && line != "routes:") print line > U
    }
    block == 2 && /^ *- name: / { name = $3 }
    block == 2 && /socket_address:/ {
      a = $0; sub(/.*address: /, "", a); sub(/,.*/, "", a)
      p = $0; sub(/.*port_value: /, "", p); sub(/ .*/, "", p)
      print name "\t" a "\t" p > C
    }' "$CONFIG"
}

# path TAB cluster TAB rewrite ("-" if none), one line per route in $tmp/routes.
route_fields() {
  awk '{
    p = "/"
    if ($0 ~ /path_separated_prefix: /) { p = $0; sub(/.*path_separated_prefix: /, "", p); sub(/ .*/, "", p) }
    c = $0; sub(/.*cluster: /, "", c); sub(/,.*/, "", c)
    r = "-"
    if ($0 ~ /prefix_rewrite: /) { r = $0; sub(/.*prefix_rewrite: /, "", r); sub(/ .*/, "", r) }
    else if ($0 ~ /substitution: /) { r = "/" }
    print p "\t" c "\t" r
  }' "$tmp/routes"
}

target_of() { # address port
  if [ "$1" = host.docker.internal ]; then echo "host:$2"; else echo "container:$1:$2"; fi
}

make_route() { # path cluster rewrite
  local match action escaped
  if [ "$1" = / ]; then match='{ prefix: / }'; else match="{ path_separated_prefix: $1 }"; fi
  action="{ cluster: $2, timeout: 15s"
  if [ "$3" = / ]; then
    # prefix_rewrite: / would turn /api/items into //items; a regex gives /items.
    escaped=$(printf '%s' "$1" | sed 's/\./\\./g')
    action="$action, regex_rewrite: { pattern: { regex: '^$escaped/*' }, substitution: / }"
  elif [ -n "$3" ]; then
    action="$action, prefix_rewrite: $3"
  fi
  printf -- '- { name: "%s %s", match: %s, route: %s } }\n' "$host" "$1" "$match" "$action"
}

# Writes $tmp/vhost and $tmp/cluster from $tmp/routes and $tmp/clusters:
# routes sorted longest prefix first ("/" last), only clusters still in use.
render_host() {
  local name c_address c_port
  {
    echo "$VH_INDENT$start_marker"
    echo "$VH_INDENT- name: $host"
    echo "$VH_INDENT  domains: [\"$host\"]"
    echo "$VH_INDENT  routes:"
    awk '{ k = 0
           if ($0 ~ /path_separated_prefix: /) { p = $0; sub(/.*path_separated_prefix: /, "", p); sub(/ .*/, "", p); k = length(p) }
           print k "\t" $0 }' "$tmp/routes" | sort -t "$(printf '\t')" -k1,1nr | cut -f2- | sed "s|^|$ROUTE_INDENT|"
    echo "$VH_INDENT$end_marker"
    echo
  } >"$tmp/vhost"
  route_fields | cut -f2 | sort -u >"$tmp/used"
  {
    echo "    $start_marker"
    while IFS="$(printf '\t')" read -r name c_address c_port; do
      grep -qxF "$name" "$tmp/used" || continue
      cat <<EOF
    - name: $name
      type: STRICT_DNS
      dns_lookup_family: V4_ONLY
      connect_timeout: 5s
      load_assignment:
        cluster_name: $name
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: $c_address, port_value: $c_port }
EOF
    done <"$tmp/clusters"
    echo "    $end_marker"
    echo
  } >"$tmp/cluster"
}

# mode: insert (new host, before the markers) | replace (existing host) | delete
write_host() {
  awk -v s="$start_marker" -v e="$end_marker" -v vm="$VH_MARKER" -v cm="$CL_MARKER" \
      -v vf="$tmp/vhost" -v cf="$tmp/cluster" -v mode="$1" '
    function emit(f,   l) { while ((getline l < f) > 0) print l; close(f) }
    after_end { after_end = 0; if ($0 == "") next }
    index($0, s) { n++; skip = 1; if (mode == "replace") emit(n == 1 ? vf : cf); next }
    skip { if (index($0, e)) { skip = 0; after_end = 1 }; next }
    mode == "insert" && index($0, vm) { emit(vf) }
    mode == "insert" && index($0, cm) { emit(cf) }
    { print }' "$tmp/envoy.yaml.bak" >"$CONFIG"
}

require_generated_shape() {
  [ ! -s "$tmp/unexpected" ] || die "the $host block in $CONFIG was edited by hand (or uses an older format); edit it by hand, or remove the whole hostname with --remove $host and add it again"
}

# --- Envoy: validate and restart ----------------------------------------------

admin() { curl -fsS --max-time 2 --unix-socket "$ADMIN_SOCKET" "$@" 2>/dev/null; }

envoy_running() {
  if [ "$MODE" = container ]; then [ "$(admin http://localhost/ready)" = LIVE ]
  else [ -n "$(docker compose ps --status running -q envoy 2>/dev/null)" ]; fi
}

validate_config() {
  if [ "$MODE" = container ]; then
    local out
    out=$(envoy --mode validate -c "$CONFIG" --log-level warn 2>&1) || { echo "$out"; return 1; }
    echo "$out"
    ! grep -qi deprecated <<<"$out"
  else
    ./scripts/validate.sh
  fi
}

restart_envoy() {
  local i status
  if [ "$MODE" = container ]; then
    # Envoy exits; its restart policy (unless-stopped) starts it again.
    admin -X POST http://localhost/quitquitquit >/dev/null || return 1
    for i in $(seq 1 50); do envoy_running || break; sleep 0.2; done
    for i in $(seq 1 60); do envoy_running && return 0; sleep 0.5; done
    return 1
  fi
  docker compose restart envoy >/dev/null 2>&1
  for i in $(seq 1 30); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q envoy)" 2>/dev/null || true)
    [ "$status" = healthy ] && return 0
    sleep 1
  done
  return 1
}

apply_and_restart() {
  if ! validate_config >"$tmp/validate.log" 2>&1; then
    cp "$tmp/envoy.yaml.bak" "$CONFIG"
    cat "$tmp/validate.log" >&2
    die "Envoy rejected the change; $CONFIG was restored"
  fi
  echo "validated $CONFIG"
  if $restart && envoy_running; then
    restart_envoy || die "Envoy did not become ready again; check: docker compose logs envoy"
    echo "restarted Envoy (ready)"
  elif $restart; then
    echo "Envoy is not running; start it with: docker compose up -d --build --wait"
  else
    echo "not restarted (--no-restart); apply with: docker compose restart envoy"
  fi
}

# --- list ----------------------------------------------------------------------

if [ "$action" = list ]; then
  for h in $(awk '/^ *# --- add-route: / && !seen[$4]++ { print $4 }' "$CONFIG"); do
    set_host "$h"
    read_host
    echo "$h"
    if [ -s "$tmp/unexpected" ]; then echo "  (edited by hand; see $CONFIG)"; continue; fi
    route_fields | while IFS="$(printf '\t')" read -r p c r; do
      line=$(awk -F '\t' -v c="$c" '$1 == c { print $2 " " $3 }' "$tmp/clusters")
      printf '  %-20s -> %s%s\n' "$p" "$(target_of ${line% *} ${line#* })" "$([ "$r" = - ] || echo "  (rewrite to $r)")"
    done
  done
  exit 0
fi

[ -n "$host" ] || usage 1
[[ $host =~ $HOST_RE ]] || die "'$host' is not a valid lowercase hostname (e.g. myapp.local.test)"
set_host "$host"
if [ -n "$path" ]; then
  [[ $path =~ $PATH_RE ]] || die "invalid --path '$path' (e.g. /api; must start with /, no trailing slash)"
fi
if [ -n "$rewrite" ]; then
  [[ $rewrite =~ $PATH_RE ]] || die "invalid --rewrite '$rewrite' (e.g. / or /v2)"
fi

# --- remove --------------------------------------------------------------------

if [ "$action" = remove ]; then
  managed || die "$host was not added by add-route.sh; remove it from $CONFIG by hand"
  if [ -z "$path" ]; then
    write_host delete
    echo "removed $host from $CONFIG"
  else
    read_host
    require_generated_shape
    route_fields | cut -f1 | grep -qxF "$path" || die "$host has no route for $path (see --list)"
    route_fields | paste - "$tmp/routes" | awk -F '\t' -v p="$path" '$1 != p { print $4 }' >"$tmp/routes.new"
    mv "$tmp/routes.new" "$tmp/routes"
    if [ -s "$tmp/routes" ]; then
      render_host
      write_host replace
      echo "removed route $host$path from $CONFIG"
    else
      write_host delete
      echo "removed route $host$path (its last route, so the whole hostname) from $CONFIG"
    fi
  fi
  apply_and_restart
  if ! managed && [ "$MODE" = host ] && grep -qE "[[:space:]]$host([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
    echo "You can also remove '$host' from /etc/hosts (sudo nano /etc/hosts)."
  fi
  exit 0
fi

# --- add -----------------------------------------------------------------------

[ -n "$target" ] || die "missing target: host:PORT or container:NAME:PORT"
case $target in
  host:*)
    address=host.docker.internal
    port=${target#host:} ;;
  container:*:*)
    rest=${target#container:}
    address=${rest%:*}
    port=${rest##*:} ;;
  *) die "target must be host:PORT or container:NAME:PORT (got '$target')" ;;
esac
[[ $address =~ $NAME_RE ]] || die "invalid container name '$address'"
[[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "invalid port '$port'"
path=${path:-/}
[ -z "$rewrite" ] || [ "$path" != / ] || die "--rewrite needs a --path other than / (rewriting the root prefix is not supported)"

if managed; then
  read_host
  require_generated_shape
  route_fields | cut -f1 | grep -qxF "$path" \
    && die "$host already routes $path (remove it first: --remove $host --path $path)"
  mode=replace
else
  grep -qF "\"$host\"" "$CONFIG" && die "$host is configured by hand in $CONFIG; edit it there"
  : >"$tmp/routes"; : >"$tmp/clusters"
  mode=insert
fi

# Reuse this host's cluster for the same target, otherwise add one.
cluster=$(awk -F '\t' -v a="$address" -v p="$port" '$2 == a && $3 == p { print $1; exit }' "$tmp/clusters")
if [ -z "$cluster" ]; then
  cluster=$(printf '%s__%s_%s' "$host" "$address" "$port" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_' '_')
  grep -qE "^ *- name: $cluster\$" "$CONFIG" && die "cluster $cluster already exists in $CONFIG"
  printf '%s\t%s\t%s\n' "$cluster" "$address" "$port" >>"$tmp/clusters"
fi
make_route "$path" "$cluster" "$rewrite" >>"$tmp/routes"
render_host
write_host "$mode"
echo "added route $host$path -> $target${rewrite:+ (rewrite to $rewrite)} to $CONFIG"
apply_and_restart

# --- Post checks: is the target reachable, is the hostname resolvable? -------
# In container mode the checks run in the routes-ui container, which is on the
# same Docker network and has the same host.docker.internal mapping as Envoy.
in_envoy() { if [ "$MODE" = container ]; then "$@"; else docker compose exec -T envoy "$@"; fi; }
if $restart && envoy_running; then
  if [ "$address" = host.docker.internal ]; then
    code=$(in_envoy curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://host.docker.internal:$port/" 2>/dev/null || true)
    [ "$code" != 000 ] && [ -n "$code" ] \
      || warn "nothing answers on port $port of this machine yet; requests to $host$path get 503 until it does"
  elif ! in_envoy getent hosts "$address" >/dev/null 2>&1; then
    warn "Envoy cannot resolve '$address': the container isn't running, or isn't on a network Envoy joined (see compose.integration.example.yaml). Requests to $host$path get 503 until it is."
  fi
fi

[ "$MODE" = container ] && exit 0   # the web UI shows its own usage hints
http_port=$(docker compose port envoy 10000 2>/dev/null | sed 's/.*://' || true)
http_port=${http_port:-${ENVOY_HTTP_PORT:-8080}}
echo
echo "Try it:  curl -H 'Host: $host' http://127.0.0.1:$http_port$path"
if grep -qE "[[:space:]]$host([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
  echo "Browser: http://$host:$http_port$path"
else
  echo "Browser: add the hostname to /etc/hosts first (README: Open in a browser):"
  echo "  echo '127.0.0.1 $host' | sudo tee -a /etc/hosts"
  echo "  then open http://$host:$http_port$path"
fi
