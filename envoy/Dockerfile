# Envoy front proxy image: the official Envoy image, pinned, plus curl and a
# small entrypoint. The configuration is not baked in; compose.yaml mounts
# ./envoy read-only at /etc/envoy, so config edits only need a restart.
ARG ENVOY_VERSION=v1.40.2
FROM envoyproxy/envoy:${ENVOY_VERSION}

# curl is used by the health check and for querying the admin interface,
# which listens only on a Unix socket.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# The admin interface listens on a Unix socket here (see envoy.yaml). compose.yaml
# mounts a shared named volume at this path, which inherits this ownership.
RUN install -d -o 101 -g 101 -m 0770 /run/envoy-admin

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 555 /usr/local/bin/entrypoint.sh

# The base image's "envoy" user.
USER 101:101

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
