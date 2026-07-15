# Peachfuzz

Web app for role-based dashboards and report pages. Users authenticate, land in a shell matched to their role, browse a folder tree of pages, and run page bodies through engines against data pipelined from external sources into a local warehouse.

---

## Quick start

```bash
# 1. App database — migrate + sample fixture
DATABASE_URL="sqlite:data/peachfuzz.db" dbmate up
sqlite3 data/peachfuzz.db < db/fixtures/sample-data.sql

# 2. Build & run (from repo root — paths are relative)
zig build run
# listens on 0.0.0.0:8000
```

Smoke checks:

```bash
http :8000/peachfuzz/healthcheck
http :8000/peachfuzz/auth/signin
```

Sample users (password `test` for all active accounts): `admin`, `jill`, `chris`, `barry`, `rebecca`, `albert.wesker`. After sign-in you are sent through `/peachfuzz/home` (role dispatcher) → currently only `analyst` has a shell (`/peachfuzz/analyst`).

Optional datamark warehouse (business pages that query the warehouse file):

```bash
# cacheable sources → data/datamark/source/<name>/  (needs clone credentials)
./zig-out/bin/peachfuzz-cmd_datamark-clone

# load into data/datamark.db (cache on disk; remote sources direct — needs their credentials)
./zig-out/bin/peachfuzz-cmd_datamark-flush
```

Source metadata and credentials live in `datamark_source*` (app DB) and the env vars each CLI documents when missing. Page engines that import third-party packages need those packages available to the interpreter on `PATH` (or under `$VIRTUAL_ENV` if set).

---

## Overview

```
                    +-----------------+
                    |     Browser     |
                    |   (UI shell)    |
                    +--------+--------+
                             |
                             | HTTP :8000
                             v
              +--------------------------------+
              |         peachfuzz exe          |
              |  routes: auth | home | analyst |
              +------+----------+------+-------+
                     |          |      |
         +-----------+   +------+      +-----------+
         v               v                         v
  +-------------+  +-----------+            +-------------+
  | auth/session|  | page tree |            |   engine    |
  | credentials |  |  render   |            |  dispatcher |
  +------+------+  +-----+-----+            +------+------+
         |               |                         |
         v               v                         v
  +-------------+  +-----------+            +-------------+
  | peachfuzz.db|  | pages_*   |            | page engine |
  | (app DB     |  | folders + |            | subprocess  |
  |  RO/RW)     |  | views     |            | (stdin body)|
  +-------------+  +-----------+            +------+------+
                                                   |
                    +------------------------------+
                    |  optional page body I/O
                    v
             +--------------+     clone/flush CLIs
             | datamark.db  | <---------------------- external sources
             | (warehouse)  |     peachfuzz-cmd_datamark-*
             +--------------+
```

Data path in one line: **sources → clone/flush → warehouse → page script → HTML in analyst shell**.

---

## Context

```
+-------------+         +------------------+         +------------------+
|    User     | ------> |    Peachfuzz     | ------> |  Identity (opt)  |
| (analyst…)  |  HTTPS  |  dashboards &    | device  |  corporate SSO   |
+-------------+  /HTTP  |  report pages    |  code   |                  |
                        +--------+---------+         +------------------+
                                 |
              +------------------+------------------+
              |                  |                  |
              v                  v                  v
     +----------------+  +--------------+  +----------------+
     | Cacheable      |  | Remote       |  |   Developer    |
     | sources        |  | object       |  | (fixtures/CLI) |
     | (clone to disk)|  | sources      |  |                |
     +----------------+  +--------------+  +----------------+
```

## Containers

```
+------------------------------------------------------------+
|                         Peachfuzz boundary                 |
|                                                            |
|  +--------------------+     +------------------+           |
|  | Web application    |     | Datamark CLIs    |           |
|  | peachfuzz          |     | clone + flush    |           |
|  | auth, home,        |     +--------+---------+           |
|  | analyst, engines   |              |                     |
|  +---------+----------+              |                     |
|            |                         |                     |
|            |  RW/RO                  |  RW                 |
|            v                         v                     |
|  +--------------------+     +------------------+           |
|  | App DB             |     | Warehouse        |           |
|  | data/peachfuzz.db  |     | data/datamark.db |           |
|  | users, sessions,   |     | source tables    |           |
|  | pages, datamark_*  |     +------------------+           |
|  | metadata           |              ^                     |
|  +--------------------+              | load source files   |
|            ^                         |                     |
|            | metadata                |                     |
|            +-------------------------+                     |
|                                                            |
|  +--------------------+     +------------------+           |
|  | Local cache        |     | Page runtime     |           |
|  | data/datamark/     |     | engine child     |           |
|  | source/<name>/…    |     | (per request)    |           |
|  +--------------------+     +------------------+           |
+------------------------------------------------------------+
```

## Components

```
main
  |-- HTTP server
  |-- handling.auth.routes     --> handlers/*  utils  session  securing  accessly
  |-- handling.home.routes     --> home-get (role dispatcher)
  |-- handling.analyst.routes  --> analyst-get, page-get, render
  `-- engine.runtime           --> backend (spawn page engine)

Shared modules: HTTP server, templates, app DB access
```

Layout under `src/peachfuzz/handling/<package>/`:

| Piece | Role |
|-------|------|
| `routes.zig` | Wire paths only |
| `handlers/*.zig` | One kebab-case file per handler |
| sibling module | Shared helpers (`auth/utils.zig`, `analyst/render.zig`) |
| `tmpl/` | Embedded HTML templates |

---

## Sign-in

```
Browser          auth handlers         session/app DB         home          analyst
   |                   |                     |                  |              |
   | GET /auth/signin  |                     |                  |              |
   |------------------>|                     |                  |              |
   |  HTML form        |                     |                  |              |
   |<------------------|                     |                  |              |
   | POST username/pw  |                     |                  |              |
   |------------------>|  authenticate       |                  |              |
   |                   |-------------------->|                  |              |
   |                   |  createSession      |                  |              |
   |                   |-------------------->|                  |              |
   |  302 + Set-Cookie |                     |                  |              |
   |  Location=/home   |                     |                  |              |
   |<------------------|                     |                  |              |
   | GET /home (cookie)|                     |                  |              |
   |---------------------------------------->| currentUser      |              |
   |                   |                     |----------------->|              |
   |                   |                     |  role=analyst    |              |
   |  302 /analyst     |                     |                  |              |
   |<-----------------------------------------------------------|              |
   | GET /analyst      |                     |                  |              |
   |-------------------------------------------------------------------------->|
   |  shell + page tree|                     |                  |              |
   |<--------------------------------------------------------------------------|
```

## Open a page

```
Browser              page-get                 runtime           page engine
   |                    |                        |                    |
   | GET /analyst/pages/herbs?mix=GR             |                    |
   |------------------->|                        |                    |
   |                    | currentUser (cookie)   |                    |
   |                    | lookup pages_view      |                    |
   |                    | collect params →       |                    |
   |                    |   ["mix=GR"]           |                    |
   |                    | Run(engine, body, args)|                    |
   |                    |----------------------->|                    |
   |                    |                        | spawn process      |
   |                    |                        | body + args        |
   |                    |                        |------------------->|
   |                    |                        |  body on stdin     |
   |                    |                        |  HTML on stdout    |
   |                    |                        |<-------------------|
   |                    | renderAnalyst(html)    |                    |
   |  200 shell+content |                        |                    |
   |<-------------------|                        |                    |
```

Convention: the page body prints its own `<form method="get">`. Every query/form param is forwarded as `name=value` engine arguments (repeated keys preserved). No param schema in the DB.

## Datamark pipeline

```
Operator     clone CLI        external sources   flush CLI         datamark.db
   |            |                |                 |                  |
   | run clone  |                |                 |                  |
   |----------->| fetch assets   |                 |                  |
   |            |--------------->|                 |                  |
   |            | write local    |                 |                  |
   |            | cache (when    |                 |                  |
   |            | source allows) |                 |                  |
   |            |                |                 |                  |
   | run flush  |                |                 |                  |
   |---------------------------------------------->|                  |
   |            |                |  read sources   |                  |
   |            |                |  (cache and/or  | load tables      |
   |            |                |   remote URI)   |----------------->|
   |            |                |<----------------|                  |
```

---

## Session

```
                    +-----------+
                    |  No auth  |
                    +-----+-----+
                          |
              sign-in OK  |  create token, Set-Cookie
                          v
                    +-----------+
              +---->|  Active   |----+
              |     +-----+-----+    |
              |           |          | expired / revoked / bad cookie
   activity   |           | sign-out |
   (valid)    |           v          |
              |     +-----------+    |
              +-----|  Revoked  |<---+
                    +-----------+
                          |
                          v
                    +-----------+
                    |  No auth  |  (cookie cleared / ignored)
                    +-----------+
```

Cookie: HttpOnly, `Path=/peachfuzz`, `SameSite=Lax`, seven-day TTL. `Secure` is off for local HTTP.

## After sign-in

```
              +--------+
              | Sign-in|
              +---+----+
                  | success
                  v
           +------+------+
           | /peachfuzz/ |
           |    home     |   role dispatcher
           +------+------+
                  |
      +-----------+-----------+-----------+
      |           |           |           |
      v           v           v           v
  +-------+  +--------+  +-------+  +---------+
  | root  |  | admin  |  | staff |  | analyst |  ← only shell today
  |  404  |  |  404   |  |  404  |  +----+----+
  +-------+  +--------+  +-------+       |
                                         | /analyst
                                         v
                                  +------+------+
                                  |  Dashboard  |
                                  |  (shell)    |
                                  +------+------+
                                         |
                          +--------------+--------------+
                          |                             |
                          v                             v
                   stay on Dashboard              GET …/pages/:name
                   Workspace + stats              engine body in pane
```

## Engine run

```
  +------------+     known id      +-------------+
  | engine_id  |------------------>|  dispatch   |
  | from DB    |                   +------+------+
  +-----+------+                          |
        | unknown                         |
        v                                 +-- unimplemented --> empty string
   log + ""                               |
                                          +-- implemented ----> spawn → stdout HTML
                                                              (nonzero exit → empty)
```

---

## Repository map

```
.
├── build.zig / build.zig.zon   # exe, lib, cmd tools, tests
├── cmd/                        # datamark-clone, datamark-flush
├── db/
│   ├── migrations/             # single init migration (edit in place pre-release)
│   ├── fixtures/sample-data.sql
│   └── schema.sql              # snapshot only — not the source of truth
├── data/                       # gitignored runtime DBs & caches
├── 3rdparty/                   # vendored headers
└── src/
    ├── main.zig / root.zig     # server entry + library re-exports
    ├── (HTTP / template / app-DB wrappers + shims)
    └── peachfuzz/
        ├── engine/             # runtime + page-engine backend
        └── handling/
            ├── auth/           # sign-in, SSO, session, roles
            ├── home/           # post-login role redirect
            └── analyst/        # dashboard shell + pages
```

---

## Routes (mental model)

| Method | Path | Behavior |
|--------|------|----------|
| GET | `/` | → `/peachfuzz/auth` |
| GET | `/peachfuzz/healthcheck` | plain health |
| GET | `/peachfuzz/auth` | → sign-in |
| GET/POST | `/peachfuzz/auth/signin` | local credentials |
| GET | `/peachfuzz/auth/signout` | revoke + clear cookie |
| GET/POST | `/peachfuzz/auth/o365/*` | device-code SSO (env config) |
| GET | `/peachfuzz/home` | session → `/peachfuzz/{role}` |
| GET | `/peachfuzz/analyst` | authenticated shell |
| GET | `/peachfuzz/analyst/pages/:name` | run page engine, embed HTML |

SSO device-code flow needs `PEACHFUZZ_O365_CLIENT_ID`, `PEACHFUZZ_O365_CLIENT_SECRET`, `PEACHFUZZ_O365_TENANT_ID`.

---

## Build & test

```bash
zig build          # install peachfuzz + cmd tools
zig build run      # server (blocking)
zig build check    # compile checks including cmd tools
zig build test     # unit + integration tests
```
