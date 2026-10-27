# app-two: go-httpbin, the maintained Go port of httpbin (the reference
# example used kennethreitz/httpbin, which only publishes `latest`).
# Useful endpoints: /anything (echo), /status/<code>, /delay/<seconds>, /headers.
FROM mccutchen/go-httpbin:2.25.0

# Image defaults: non-root user 65532, listens on :8080.
# The image has no shell or HTTP client, so there is no HEALTHCHECK.
EXPOSE 8080
