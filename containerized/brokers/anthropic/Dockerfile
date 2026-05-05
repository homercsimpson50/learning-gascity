# gc-broker-anthropic — reverse proxy that injects the host's Anthropic
# OAuth token (extracted from macOS Keychain by the host-side extractor)
# into agent requests bound for api.anthropic.com.
#
# Spec: docs/credential-broker-v2-spec.md §6, §7.1.
# Hard rule (§6.3): no shell beyond dpkg's dash, no curl/wget/nc.

FROM python:3.12-slim

RUN pip install --no-cache-dir aiohttp==3.9.5 \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY proxy.py /app/proxy.py

WORKDIR /app
USER 1000:1000

CMD ["python3", "/app/proxy.py"]
