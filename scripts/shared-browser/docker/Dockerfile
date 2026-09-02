FROM debian:trixie-slim
# xdotool は「貼り付けを禁止しているフォーム」向けの直接キー入力用 (shared-browser type)。
# ⚠ xdotool は UTF-8 を扱うのに LC_CTYPE が要る。C.UTF-8 は glibc 組み込みなので
#   locales パッケージは不要だが、呼ぶ側で LC_ALL=C.UTF-8 を渡すこと。
#
# ⚠ x11-utils (xdpyinfo / xprop) が無いと entrypoint の X 起動待ちループが
#   毎回 50 回とも失敗して「ただ 10 秒眠るだけ」になる (2026-09-02 に発覚。
#   Xvfb がその 10 秒で上がるので今まで露見していなかった)。XIM の登録待ちにも要る。
#
# fcitx5 + anthy は noVNC 画面から直接かな漢字変換で打つため (IME=1 のとき)。
# 🔴 これが成立するのは **XIM が X11 接続の上で喋る**から。ブラウザはホストに
#    あるが X サーバは共有しているので、コンテナ内の fcitx5 がホストの Chrome へ
#    そのまま繋がる。**ホスト側に入れるものは何も無い** (GTK の im-xim.so は
#    libgtk-3-0t64 = Chrome 自身の依存に最初から入っている)。
# 🔴 **mozc ではなく anthy を使う。**Debian trixie の mozc-server はこの環境で
#    起動できない (mozc_server も mozc_renderer も --help ですら exit 255。
#    共有ライブラリの不足なし・AppArmor 拒否なし・root でも非 root でも同じ・
#    AVX2 あり・動的リンクは正常完了するので main() が即 -1 を返している)。
#    しかも **mozc を既定 IM にすると fcitx5 のメインループごと固まり**、
#    fcitx5-remote が応答しなくなって IME 全体が死ぬ (profile から外すと即座に回復)。
# ⚠ fonts-ipafont-gothic は fcitx5 が preedit と候補を描くのに要る (無いと豆腐)。
# ⚠ locales + ja_JP.UTF-8 が要る。Xlib の XIM は locale.dir にあるロケールでしか
#   動かず、C.UTF-8 は locale.alias で en_US.UTF-8 に化ける。
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11vnc novnc websockify openbox procps x11-xserver-utils x11-utils xdotool \
      fcitx5 fcitx5-anthy fonts-ipafont-gothic dbus-x11 locales \
 && echo 'ja_JP.UTF-8 UTF-8' > /etc/locale.gen && locale-gen \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
