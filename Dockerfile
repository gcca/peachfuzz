# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.23
ARG DEPS_IMAGE=ghcr.io/gcca/peachfuzz-deps:latest
ARG DBMATE_IMAGE=ghcr.io/amacneil/dbmate:2.33.0

FROM ${DBMATE_IMAGE} AS dbmate

# Native-arch toolchain: this stage actually executes (zig build runs here),
# so it must match the build host, not the final image target. Running a
# target-arch zig under emulation crashes on Apple Silicon build hosts either
# way: SIGSEGV under qemu-user, "bss_size overflow" under Rosetta.
FROM --platform=$BUILDPLATFORM ${DEPS_IMAGE} AS deps

# Target-arch artifact source: never executed, only used to harvest
# target-arch duckdb/sqlite3 libraries for cross-linking. Zig cross-compiles
# its own libc/libc++ for any -Dtarget, but duckdb/sqlite3 are prebuilt/system
# libraries that must match the OUTPUT architecture, not the build host.
FROM --platform=$TARGETPLATFORM ${DEPS_IMAGE} AS deps-target

FROM deps AS build

ARG TARGETARCH

WORKDIR /src

COPY build.zig build.zig.zon ./
COPY 3rdparty ./3rdparty
COPY src ./src
COPY cmd ./cmd
COPY db ./db

COPY --from=deps-target /usr/local/lib/libduckdb.so /usr/local/lib/libduckdb.so
COPY --from=deps-target /usr/local/include/duckdb.h /usr/local/include/duckdb.hpp /usr/local/include/
COPY --from=deps-target /usr/lib/libsqlite3.so* /usr/lib/
COPY --from=deps-target /usr/include/sqlite3.h /usr/include/sqlite3ext.h /usr/include/

RUN case "${TARGETARCH}" in \
        amd64) ZIG_TARGET=x86_64-linux-musl ;; \
        arm64) ZIG_TARGET=aarch64-linux-musl ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && zig build -Doptimize=ReleaseFast -Dduckdb-prefix=/usr/local -Dtarget="${ZIG_TARGET}"

FROM alpine:${ALPINE_VERSION} AS execute

RUN apk add --no-cache \
    ca-certificates \
    curl \
    libstdc++ \
    python3 \
    sqlite \
    sqlite-libs

WORKDIR /app

COPY --from=build /src/zig-out/bin/ /usr/local/bin/
COPY --from=build /usr/local/lib/libduckdb.so /usr/local/lib/libduckdb.so
COPY --from=dbmate /usr/local/bin/dbmate /usr/local/bin/dbmate
COPY db/migrations/*.sql /app/migrations/
COPY db/fixtures/*.sql /app/fixtures/
COPY docker-entrypoint.sh /usr/local/bin/peachfuzz-entrypoint

RUN chmod +x /usr/local/bin/peachfuzz-entrypoint \
    && mkdir -p /app/data

ENV LD_LIBRARY_PATH=/usr/local/lib \
    TZ=UTC \
    DB_URL=/app/data/peachfuzz.db \
    LOAD_SAMPLE_DATA=0

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -fs http://127.0.0.1:8000/peachfuzz/healthcheck >/dev/null || exit 1

ENTRYPOINT ["peachfuzz-entrypoint"]
