FROM debian:trixie-slim
# xdotool は「貼り付けを禁止しているフォーム」向けの直接キー入力用 (shared-browser type)。
# ⚠ xdotool は UTF-8 を扱うのに LC_CTYPE が要る。C.UTF-8 は glibc 組み込みなので
#   locales パッケージは不要だが、呼ぶ側で LC_ALL=C.UTF-8 を渡すこと。
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11vnc novnc websockify openbox procps x11-xserver-utils xdotool \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
