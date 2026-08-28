FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11vnc novnc websockify openbox procps x11-xserver-utils \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
