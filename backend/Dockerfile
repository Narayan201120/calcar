# syntax=docker/dockerfile:1

# Build context is the REPO ROOT (not backend/), because the Go module lives
# at backend/ and import paths are github.com/calcar/calcar/backend/... .
# Build with:  docker build -f backend/Dockerfile .
# Compose already sets this (context: . + dockerfile: backend/Dockerfile).

FROM golang:1.27-bookworm AS build
WORKDIR /src
COPY backend/go.mod backend/go.sum ./backend/
RUN cd backend && go mod download
COPY backend/ ./backend/
RUN CGO_ENABLED=0 GOFLAGS=-mod=readonly go build -trimpath -ldflags="-s -w" -o /api ./backend/cmd/calcar-api

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates wget \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 65532 -m appuser
COPY --from=build /api /usr/local/bin/api
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider "http://127.0.0.1:${PORT:-8080}/healthz" || exit 1
ENTRYPOINT ["/usr/local/bin/api"]
