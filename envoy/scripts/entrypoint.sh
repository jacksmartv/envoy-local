#!/bin/sh
# Start Envoy with the mounted configuration.
#
# Like the reference front-proxy example, it prints the effective settings
# (and optionally the configuration) before starting Envoy. Unlike it, it does
# not rewrite the YAML: the mounted file is exactly what Envoy loads.
#
# Environment:
#   ENVOY_CONFIG       config path         (default /etc/envoy/envoy.yaml)
#   ENVOY_LOG_LEVEL    Envoy log level     (default info)
#   ENVOY_DUMP_CONFIG  "true" prints the config file at startup
#
# Extra arguments are passed to Envoy, e.g. `--mode validate`.
set -eu

config="${ENVOY_CONFIG:-/etc/envoy/envoy.yaml}"
log_level="${ENVOY_LOG_LEVEL:-info}"

if [ ! -r "$config" ]; then
  echo "entrypoint: config file $config is missing or unreadable" >&2
  exit 1
fi

printf '***** %s | config: %s | log level: %s *****\n' \
  "$(envoy --version | grep -o 'version: [^ ]*' | cut -d/ -f2)" "$config" "$log_level"

if [ "${ENVOY_DUMP_CONFIG:-false}" = "true" ]; then
  printf '***** Dumping %s *****\n' "$config"
  cat "$config"
fi

exec envoy -c "$config" --log-level "$log_level" "$@"
