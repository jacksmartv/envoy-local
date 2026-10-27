# Routes web UI. Built on the same pinned Envoy image as the proxy, so that
# scripts/add-route.sh can validate envoy.yaml with the exact same Envoy binary.
ARG ENVOY_VERSION=v1.40.2
FROM envoyproxy/envoy:${ENVOY_VERSION}

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-yaml curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Mount point for the shared admin-socket volume (same ownership as in envoy/Dockerfile).
RUN install -d -o 101 -g 101 -m 0770 /run/envoy-admin

COPY server.py /app/server.py

USER 101:101
WORKDIR /workspace
EXPOSE 8090
HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
  CMD ["curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8090/healthz"]

ENTRYPOINT ["python3", "/app/server.py"]
