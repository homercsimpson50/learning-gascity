# gc-broker-github-api — reverse proxy that injects GH_TOKEN into agent
# requests bound for api.github.com. Path/method/repo allowlist enforced.
#
# Spec: docs/credential-broker-v2-spec.md §6, §7.2.

FROM python:3.12-slim

RUN pip install --no-cache-dir aiohttp==3.9.5 \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY proxy.py /app/proxy.py

WORKDIR /app
USER 1000:1000

CMD ["python3", "/app/proxy.py"]
