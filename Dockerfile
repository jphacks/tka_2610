# 公開用のサーバー（Render など）の入れ物。リポジトリの直下で `docker build .` する。
# 3 段で作る：Web のビルド（Node）→ サーバーのビルド（Rust）→ 動かす入れ物（ビルドの道具は入れない）。
# 動かすときに要る環境変数は DATABASE_URL だけ（Render の管理画面で設定する。PORT は Render が入れる）。
# 手順は docs/deploy.md。

# ---------- 1. Web（React + Vite）----------
FROM node:22-bookworm-slim AS web
WORKDIR /app/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# ---------- 2. サーバー（Rust）----------
FROM rust:1-slim-bookworm AS server
WORKDIR /app/backend
# マイグレーション（sqlx::migrate!）と catalog.json などは、ビルドするときに埋め込むので、ソースと一緒に置く
COPY backend/ ./
RUN cargo build --release

# ---------- 3. 動かす入れ物 ----------
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=server /app/backend/target/release/backend /app/backend
COPY backend/static /app/static
COPY --from=web /app/web/dist /app/web
# 登録した写真・GLB の保存先。Render の無料のサーバーは再起動で消える（サンプルの作品は起動のたびに作り直される）
ENV STATIC_DIR=/app/static \
    WEB_DIST=/app/web \
    MEDIA_DIR=/app/data/media \
    PORT=8080
EXPOSE 8080
CMD ["/app/backend"]
