FROM rust:1.90-slim-trixie AS builder
RUN apt-get update && apt-get install -y --no-install-recommends g++ pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY preview.html ./preview.html
COPY public ./public
COPY studio ./studio
COPY migrations ./migrations
ARG CARGO_BUILD_JOBS=2
RUN cargo build --release --locked

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3t64 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/inview-backend /usr/local/bin/inview-backend
RUN mkdir /data && chown 10001:10001 /data
USER 10001:10001
WORKDIR /data
ENV INVIEW_BIND=0.0.0.0:3000
ENV INVIEW_SCAN_DIR=/data/scans INVIEW_STREAM_DIR=/data/streams
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/inview-backend"]
