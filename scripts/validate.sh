#!/usr/bin/env bash
# Validate the Compose file and the Envoy configuration without starting the stack.
#
# Envoy is validated with `envoy --mode validate` inside the same pinned image,
# user and read-only mount that compose.yaml uses, so the result applies to the
# configuration that will actually run. Deprecation warnings fail validation
# because they mean a field will be removed in a future Envoy release.
#
#   ./scripts/validate.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> docker compose config"
docker compose config --quiet
echo "compose.yaml OK"

echo "==> docker compose build envoy"
docker compose build --quiet envoy

echo "==> envoy --mode validate"
# The entrypoint adds `-c /etc/envoy/envoy.yaml --log-level warn`.
output=$(docker compose run --rm --no-deps -T -e ENVOY_LOG_LEVEL=warn envoy \
  --mode validate 2>&1) || {
  echo "$output"
  echo "FAIL: Envoy rejected the configuration" >&2
  exit 1
}
echo "$output"

if grep -qi 'deprecated' <<<"$output"; then
  echo "FAIL: configuration uses deprecated fields (see warnings above)" >&2
  exit 1
fi
