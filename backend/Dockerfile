FROM rust:1.90-slim AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
RUN cargo build --release --locked || cargo build --release

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/inview-backend /usr/local/bin/inview-backend
ENV INVIEW_BIND=0.0.0.0:3000
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/inview-backend"]
