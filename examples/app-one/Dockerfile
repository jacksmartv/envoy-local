FROM python:3.13.18-alpine3.24

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SERVICE_NAME=app-one \
    PORT=8000

WORKDIR /app
COPY server.py .

USER 65534:65534
EXPOSE 8000

HEALTHCHECK --interval=5s --timeout=2s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen(f\"http://127.0.0.1:{os.environ['PORT']}/healthz\", timeout=2)"]

CMD ["python", "server.py"]
