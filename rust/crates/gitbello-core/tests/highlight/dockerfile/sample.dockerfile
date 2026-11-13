# syntax=docker/dockerfile:1
# Comment
ARG RUST_VERSION=1.85
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-slim AS build

WORKDIR /src
ENV CARGO_HOME=/cargo PATH="/cargo/bin:$PATH"
ENV LEGACY value with spaces
LABEL org.opencontainers.image.title="gitbello" version="1.1.0"
COPY --from=deps --chown=app:app Cargo.toml Cargo.lock ./
RUN --mount=type=cache,target=/cargo \
    apt-get update && apt-get install -y git \
    && cargo build --release # trailing
EXPOSE 8080/tcp 9000

FROM debian:bookworm-slim
USER app
HEALTHCHECK --interval=30s CMD curl -f http://localhost:8080/ || exit 1
ENTRYPOINT ["/usr/bin/gitbello", "--serve"]
CMD echo "started $HOME"
onbuild run make
