# syntax=docker/dockerfile:1.7

ARG PYTHON_VERSION=3.12
ARG DEBIAN_CODENAME=trixie
ARG ZIG_VERSION=0.16.0
ARG DUCKDB_VERSION=1.5.4
ARG DBMATE_IMAGE=ghcr.io/amacneil/dbmate:2.33.0
ARG XA6_IMAGE=ghcr.io/gcca/xa6:latest

FROM ${DBMATE_IMAGE} AS dbmate

FROM ${XA6_IMAGE} AS xa6

FROM debian:${DEBIAN_CODENAME}-slim AS target-deps

RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && cp -L /usr/lib/*/libsqlite3.so /usr/local/lib/libsqlite3.so \
    && rm -rf /var/lib/apt/lists/*

FROM --platform=$TARGETPLATFORM debian:${DEBIAN_CODENAME}-slim AS build

ARG ZIG_VERSION
ARG TARGETPLATFORM

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       curl \
       libgrpc++-dev \
       libprotobuf-dev \
       pkg-config \
       protobuf-compiler \
       protobuf-compiler-grpc \
       tar \
       xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN case "$(uname -m)" in \
        x86_64) ZIG_ARCH=x86_64 ;; \
        aarch64 | arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "Unsupported build architecture: $(uname -m)" >&2; exit 1 ;; \
    esac \
    && mkdir -p /opt/zig \
    && curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
       "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
       -o /tmp/zig.tar.xz \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

COPY --from=target-deps /usr/local/lib/libsqlite3.so /usr/lib/libsqlite3.so
COPY --from=target-deps /usr/include/sqlite3.h /usr/include/sqlite3ext.h /usr/include/

WORKDIR /src

COPY build.zig build.zig.zon ./
COPY 3rdparty ./3rdparty
COPY protos ./protos
COPY src ./src

RUN --mount=type=cache,id=peachfuzz-zig-global-${TARGETPLATFORM},target=/root/.cache/zig,sharing=locked \
    --mount=type=cache,id=peachfuzz-zig-local-${TARGETPLATFORM},target=/src/.zig-cache,sharing=locked \
    echo "Building Zig for ${TARGETPLATFORM} (baseline CPU) on $(uname -m)" \
    && zig build -Doptimize=ReleaseFast -Dcpu=baseline

FROM python:${PYTHON_VERSION}-slim-${DEBIAN_CODENAME} AS execute

ARG DUCKDB_VERSION
ARG BUILDPLATFORM
ARG TARGETPLATFORM

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       libgrpc++1.51t64 \
       libsqlite3-0 \
       libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m pip install \
       --disable-pip-version-check \
       --no-cache-dir \
       --only-binary=:all: \
       --root-user-action=ignore \
       "duckdb==${DUCKDB_VERSION}" \
    && if [ "$BUILDPLATFORM" = "$TARGETPLATFORM" ]; then \
         python3 -c \
           'import duckdb; assert duckdb.sql("SELECT 42").fetchone() == (42,)'; \
       else \
         echo "cross-build ($BUILDPLATFORM -> $TARGETPLATFORM): skipping duckdb import check (its native extension segfaults/hangs under QEMU)"; \
       fi

WORKDIR /app

COPY --from=build /src/zig-out/bin/ /usr/local/bin/
COPY --from=xa6 /usr/local/bin/xa6 /opt/xa6/bin/xa6
COPY --from=xa6 /usr/local/lib/libduckdb.so /opt/xa6/lib/libduckdb.so
COPY --from=dbmate /usr/local/bin/dbmate /usr/local/bin/dbmate
COPY db/migrations/*.sql /app/migrations/
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/peachfuzz-entrypoint

ENV LD_LIBRARY_PATH=/usr/local/lib \
    TZ=UTC \
    DBPATH=/app/data/peachfuzz.db \
    PEACHFUZZ_XA6_BIN=/opt/xa6/bin/xa6 \
    PEACHFUZZ_XA6_LIBDIR=/opt/xa6/lib \
    XA6_CON_DDB_PATH=/app/data/datamark.db

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -fs http://127.0.0.1:8000/peachfuzz/healthcheck >/dev/null || exit 1

ENTRYPOINT ["peachfuzz-entrypoint"]
