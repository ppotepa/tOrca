FROM rust:1.94-bookworm AS builder
WORKDIR /src
COPY infra/relay/docker/Cargo.toml ./Cargo.toml
COPY Cargo.lock ./
COPY common ./common
COPY packages ./packages
COPY services ./services
RUN cargo build --release -p torchat-relay

FROM debian:bookworm-slim
RUN useradd --system --uid 10001 --create-home torchat
COPY --from=builder /src/target/release/torchat-relay /usr/local/bin/torchat-relay
USER torchat
ENV TORCHAT_BIND=0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/torchat-relay"]
