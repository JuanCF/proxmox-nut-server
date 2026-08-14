# syntax=docker/dockerfile:1

# Multi-stage build for NutWatch.
# Stage 1 builds the React frontend; Stage 2 is the runtime image with NUT.

FROM node:22-slim AS frontend-builder
# Build the React SPA. Vite writes to ../backend/static, so we copy the
# backend tree into the same relative location before building.
WORKDIR /build/src/frontend
COPY src/frontend/package.json src/frontend/package-lock.json ./
RUN npm ci
COPY src/frontend/ ./
COPY src/backend/ /build/src/backend/
RUN npm run build

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV NUTWATCH_DIR=/opt/nutwatch
ENV NUTWATCH_HOST=0.0.0.0
ENV NUTWATCH_PORT=8081
ENV NUT_LISTEN_ADDR=0.0.0.0
ENV NUT_LISTEN_PORT=3493
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    nut-server \
    nut-client \
    usbutils \
    python3 \
    python3-venv \
    supervisor \
    tini \
    curl \
    openssl \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nut/ups.conf /etc/nut/upsd.conf /etc/nut/upsd.users \
             /etc/nut/upsmon.conf /etc/nut/nut.conf

WORKDIR $NUTWATCH_DIR

# Copy backend application with freshly built frontend static files.
COPY --from=frontend-builder /build/src/backend/ $NUTWATCH_DIR/

# Install Python dependencies.
RUN python3 -m venv $NUTWATCH_DIR/venv \
    && $NUTWATCH_DIR/venv/bin/pip install --no-cache-dir -r $NUTWATCH_DIR/requirements.txt

# Copy Docker runtime helpers.
COPY scripts/docker/entrypoint.sh /entrypoint.sh
COPY scripts/docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY scripts/docker/systemctl-shim.sh /usr/local/bin/systemctl
COPY scripts/docker/upsmon-wrapper.sh /usr/local/bin/upsmon-wrapper

RUN chmod +x /entrypoint.sh /usr/local/bin/systemctl /usr/local/bin/upsmon-wrapper \
    && mkdir -p /etc/nut/notify.d /var/log/nut /var/run/nut /var/lib/nutwatch /var/log/supervisor \
    && chown -R root:nut /etc/nut \
    && chmod 750 /etc/nut /etc/nut/notify.d \
    && chown nut:nut /var/log/nut /var/run/nut \
    && chmod 755 /var/lib/nutwatch

# Persist NUT configuration and NutWatch data (accounts, history, API keys).
VOLUME ["/etc/nut", "/var/lib/nutwatch"]

EXPOSE 8081 3493

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
