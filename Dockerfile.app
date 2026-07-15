# syntax=docker/dockerfile:1.7

ARG PYTHON_VERSION=3.12
ARG DEBIAN_CODENAME=trixie
ARG DUCKDB_VERSION=1.5.4
ARG DEPS_IMAGE=peachfuzz-deps:latest

FROM ${DEPS_IMAGE} AS deps

FROM deps AS ocaml-build

WORKDIR /src

COPY dune-project ./
COPY cmd/dune cmd/*.ml ./cmd/

RUN eval $(opam env) \
    && dune build --profile=release @install \
    && dune install --profile=release --prefix=/out --bindir=/out peachfuzz

FROM deps AS build

ARG TARGETPLATFORM

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
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,from=deps,source=/opt/wheels,target=/tmp/wheels \
    python3 -m pip install \
       --disable-pip-version-check \
       --no-cache-dir \
       --no-index \
       --find-links=/tmp/wheels \
       --root-user-action=ignore \
       "duckdb==${DUCKDB_VERSION}" \
    && if [ "$BUILDPLATFORM" = "$TARGETPLATFORM" ]; then \
         python3 -c \
           'import duckdb; assert duckdb.sql("SELECT 42").fetchone() == (42,)'; \
       else \
         echo "cross-build ($BUILDPLATFORM -> $TARGETPLATFORM): skipping duckdb import check (its native extension segfaults/hangs under QEMU)"; \
       fi

COPY --from=deps /root/quicklisp /root/quicklisp
COPY --from=deps /root/.cache/common-lisp /root/.cache/common-lisp

RUN ln -sf "$(find /usr/lib -name 'libargon2.so.1' | head -n1)" /usr/local/lib/libargon2.so \
    && if [ "$BUILDPLATFORM" = "$TARGETPLATFORM" ]; then \
         sbcl --non-interactive --load /root/quicklisp/setup.lisp \
              --eval '(ql:quickload (list :cffi :sqlite :unix-opts) :silent t)'; \
       else \
         echo "cross-build ($BUILDPLATFORM -> $TARGETPLATFORM): quicklisp fasls compile at first runtime"; \
       fi

WORKDIR /app

COPY --from=build /src/zig-out/bin/ /usr/local/bin/
COPY --from=deps /usr/local/lib/libduckdb.so /usr/local/lib/libduckdb.so
COPY --from=deps /opt/xa6/bin/xa6 /opt/xa6/bin/xa6
COPY --from=deps /opt/xa6/lib/libduckdb.so /opt/xa6/lib/libduckdb.so
COPY --from=ocaml-build /out/ /usr/local/bin/
COPY --chmod=755 cmd/peachfuzz-change_user_password.lisp /usr/local/bin/peachfuzz-change_user_password
COPY --from=deps /opt/vendor/bin/dbmate /usr/local/bin/dbmate
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
