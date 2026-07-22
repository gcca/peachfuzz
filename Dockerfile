# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.23
ARG PYTHON_VERSION=3.12
ARG DEBIAN_CODENAME=bookworm
ARG ZIG_VERSION=0.16.0
ARG DUCKDB_VERSION=1.5.4
ARG DBMATE_IMAGE=ghcr.io/amacneil/dbmate:2.33.0

FROM ${DBMATE_IMAGE} AS dbmate

FROM debian:${DEBIAN_CODENAME}-slim AS target-deps

RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && cp -L /usr/lib/*/libsqlite3.so /usr/local/lib/libsqlite3.so \
    && rm -rf /var/lib/apt/lists/*

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS build

ARG ZIG_VERSION
ARG DUCKDB_VERSION
ARG TARGETPLATFORM

RUN apk add --no-cache \
    build-base \
    ca-certificates \
    curl \
    libstdc++ \
    tar \
    unzip \
    xz

RUN case "$(uname -m)" in \
        x86_64) ZIG_ARCH=x86_64 ;; \
        aarch64 | arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "Unsupported build architecture: $(uname -m)" >&2; exit 1 ;; \
    esac \
    && mkdir -p /opt/zig \
    && curl -fsSL \
       "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt/zig --strip-components=1

ENV PATH="/opt/zig:${PATH}"

RUN case "${TARGETPLATFORM}" in \
        linux/amd64) DUCKDB_ARCH=amd64 ;; \
        linux/arm64) DUCKDB_ARCH=arm64 ;; \
        *) echo "Unsupported target platform: ${TARGETPLATFORM}" >&2; exit 1 ;; \
    esac \
    && mkdir -p /usr/local/include \
    && curl -fsSL \
       "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/libduckdb-linux-${DUCKDB_ARCH}.zip" \
       -o /tmp/libduckdb.zip \
    && unzip /tmp/libduckdb.zip -d /tmp/duckdb \
    && cp /tmp/duckdb/libduckdb.so /usr/local/lib/ \
    && cp /tmp/duckdb/duckdb.h /tmp/duckdb/duckdb.hpp /usr/local/include/ \
    && rm -rf /tmp/libduckdb.zip /tmp/duckdb

COPY --from=target-deps /usr/local/lib/libsqlite3.so /usr/lib/libsqlite3.so
COPY --from=target-deps /usr/include/sqlite3.h /usr/include/sqlite3ext.h /usr/include/

WORKDIR /src

COPY build.zig build.zig.zon ./
COPY 3rdparty ./3rdparty
COPY src ./src
COPY cmd ./cmd

RUN --mount=type=cache,id=peachfuzz-zig-global-${TARGETPLATFORM},target=/root/.cache/zig,sharing=locked \
    --mount=type=cache,id=peachfuzz-zig-local-${TARGETPLATFORM},target=/src/.zig-cache,sharing=locked \
    echo "Building with native $(uname -m) Zig for ${TARGETPLATFORM}" \
    && case "${TARGETPLATFORM}" in \
        linux/amd64) ZIG_TARGET=x86_64-linux-gnu.2.36 ;; \
        linux/arm64) ZIG_TARGET=aarch64-linux-gnu.2.36 ;; \
        *) echo "Unsupported target platform: ${TARGETPLATFORM}" >&2; exit 1 ;; \
    esac \
    && zig build -Doptimize=ReleaseFast -Dduckdb-prefix=/usr/local -Dtarget="${ZIG_TARGET}"

FROM python:${PYTHON_VERSION}-slim-${DEBIAN_CODENAME} AS execute

ARG DUCKDB_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       libsqlite3-0 \
       libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m pip install \
       --disable-pip-version-check \
       --no-cache-dir \
       --only-binary=:all: \
       --root-user-action=ignore \
       "duckdb==${DUCKDB_VERSION}" \
    && python3 -c \
       'import duckdb; assert duckdb.sql("SELECT 42").fetchone() == (42,)'

WORKDIR /app

COPY --from=build /src/zig-out/bin/ /usr/local/bin/
COPY --from=build /usr/local/lib/libduckdb.so /usr/local/lib/libduckdb.so
COPY --from=dbmate /usr/local/bin/dbmate /usr/local/bin/dbmate
COPY db/migrations/*.sql /app/migrations/
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/peachfuzz-entrypoint

ENV LD_LIBRARY_PATH=/usr/local/lib \
    TZ=UTC \
    DBPATH=/app/data/peachfuzz.db

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -fs http://127.0.0.1:8000/peachfuzz/healthcheck >/dev/null || exit 1

ENTRYPOINT ["peachfuzz-entrypoint"]
