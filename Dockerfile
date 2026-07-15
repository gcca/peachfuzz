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

FROM target-deps AS ocaml-build

ENV OPAMROOTISOK=1 OPAMYES=1 OPAMCONFIRMLEVEL=unsafe-yes

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       git \
       libffi-dev \
       m4 \
       ocaml-nox \
       opam \
       pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN opam init --bare --disable-sandboxing --yes \
    && opam switch create default ocaml-system \
    && opam install --yes dune sqlite3 ctypes ctypes-foreign

WORKDIR /src

COPY dune-project ./
COPY cmd/dune cmd/*.ml ./cmd/

RUN eval $(opam env) \
    && dune build --profile=release @install \
    && dune install --profile=release --prefix=/out --bindir=/out peachfuzz

FROM --platform=$TARGETPLATFORM debian:${DEBIAN_CODENAME}-slim AS build

ARG ZIG_VERSION
ARG DUCKDB_VERSION
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
       unzip \
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
COPY protos ./protos
COPY src ./src
COPY cmd ./cmd

RUN --mount=type=cache,id=peachfuzz-zig-global-${TARGETPLATFORM},target=/root/.cache/zig,sharing=locked \
    --mount=type=cache,id=peachfuzz-zig-local-${TARGETPLATFORM},target=/src/.zig-cache,sharing=locked \
    echo "Building Zig for ${TARGETPLATFORM} (baseline CPU) on $(uname -m)" \
    && zig build -Doptimize=ReleaseFast -Dduckdb-prefix=/usr/local -Dcpu=baseline

FROM --platform=$BUILDPLATFORM debian:${DEBIAN_CODENAME}-slim AS lisp-deps

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl sbcl \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
       https://beta.quicklisp.org/quicklisp.lisp -o /tmp/quicklisp.lisp \
    && sbcl --non-interactive --load /tmp/quicklisp.lisp \
       --eval '(quicklisp-quickstart:install :path "/root/quicklisp/")' \
    && sbcl --non-interactive --load /root/quicklisp/setup.lisp \
       --eval '(ql:quickload (list :cffi :sqlite :unix-opts) :silent t)' \
    && rm /tmp/quicklisp.lisp

FROM python:${PYTHON_VERSION}-slim-${DEBIAN_CODENAME} AS execute

ARG DUCKDB_VERSION
ARG BUILDPLATFORM
ARG TARGETPLATFORM

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       libargon2-1 \
       libffi8 \
       libgrpc++1.51t64 \
       libsqlite3-0 \
       libstdc++6 \
       sbcl \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m pip install \
       --disable-pip-version-check \
       --no-cache-dir \
       --only-binary=:all: \
       --root-user-action=ignore \
       "duckdb==${DUCKDB_VERSION}" \
    && python3 -c \
       'import duckdb; assert duckdb.sql("SELECT 42").fetchone() == (42,)'

COPY --from=lisp-deps /root/quicklisp /root/quicklisp

RUN ln -sf "$(find /usr/lib -name 'libargon2.so.1' | head -n1)" /usr/local/lib/libargon2.so \
    && if [ "$BUILDPLATFORM" = "$TARGETPLATFORM" ]; then \
         sbcl --non-interactive --load /root/quicklisp/setup.lisp \
              --eval '(ql:quickload (list :cffi :sqlite :unix-opts) :silent t)'; \
       else \
         echo "cross-build ($BUILDPLATFORM -> $TARGETPLATFORM): quicklisp fasls compile at first runtime"; \
       fi

WORKDIR /app

COPY --from=build /src/zig-out/bin/ /usr/local/bin/
COPY --from=build /usr/local/lib/libduckdb.so /usr/local/lib/libduckdb.so
COPY --from=xa6 /usr/local/bin/xa6 /opt/xa6/bin/xa6
COPY --from=xa6 /usr/local/lib/libduckdb.so /opt/xa6/lib/libduckdb.so
COPY --from=ocaml-build /out/ /usr/local/bin/
COPY --chmod=755 cmd/peachfuzz-change_user_password.lisp /usr/local/bin/peachfuzz-change_user_password
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
