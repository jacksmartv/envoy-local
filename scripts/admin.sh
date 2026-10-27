#!/usr/bin/env bash
# Query the Envoy admin interface, which listens only on a Unix socket inside
# the Envoy container (/run/envoy-admin/admin.sock) and is never published.
#
#   ./scripts/admin.sh                    # /ready
#   ./scripts/admin.sh /clusters          # endpoints and health per cluster
#   ./scripts/admin.sh /config_dump       # full active configuration (JSON)
#   ./scripts/admin.sh '/stats?filter=upstream_rq_5xx'
#   ./scripts/admin.sh /help              # list all admin endpoints
set -euo pipefail
cd "$(dirname "$0")/.."

exec docker compose exec -T envoy curl -fsS --unix-socket /run/envoy-admin/admin.sock "http://localhost${1:-/ready}"
