-- migrate:up

CREATE TABLE auth_user (
  username TEXT NOT NULL PRIMARY KEY,
  password BLOB NOT NULL,
  role INTEGER NOT NULL DEFAULT 3 CHECK (role IN (0, 1, 2, 3)),
  is_active BOOL NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
  last_logged_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE auth_session (
  token TEXT NOT NULL PRIMARY KEY,
  username TEXT NOT NULL REFERENCES auth_user(username) ON DELETE CASCADE,
  revoked INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1)),
  created_at INTEGER DEFAULT (unixepoch()),
  expires_at INTEGER NOT NULL
);

CREATE INDEX idx_auth_session_username ON auth_session(username);
CREATE INDEX idx_auth_session_expires_at ON auth_session(expires_at);

CREATE TRIGGER update_last_logged_at
AFTER UPDATE ON auth_session
FOR EACH ROW
WHEN NEW.username IS NOT NULL
BEGIN
  UPDATE auth_user SET last_logged_at = unixepoch() WHERE username = NEW.username;
END;

CREATE TABLE pages_folder (
  key INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  parent INTEGER REFERENCES pages_folder(key) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE pages_view (
  name TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  engine INTEGER NOT NULL CHECK (engine IN (0, 1, 2, 3, 4, 5)),
  body TEXT NOT NULL,
  folder INTEGER REFERENCES pages_folder(key) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE datamark_source (
  name TEXT PRIMARY KEY NOT NULL,
  kind INTEGER NOT NULL CHECK (kind IN (0, 1, 2, 3)),
  description TEXT NOT NULL DEFAULT ''
);
CREATE INDEX datamark_source_name_idx ON datamark_source(name);

CREATE TABLE datamark_source_github (
  source_name TEXT PRIMARY KEY NOT NULL REFERENCES datamark_source(name) ON UPDATE CASCADE ON DELETE CASCADE,
  org TEXT NOT NULL,
  repo TEXT NOT NULL,
  release TEXT NOT NULL,
  asset TEXT NOT NULL
);

CREATE TABLE datamark_source_drive (
  source_name TEXT PRIMARY KEY NOT NULL REFERENCES datamark_source(name) ON UPDATE CASCADE ON DELETE CASCADE,
  fpath TEXT NOT NULL
);

CREATE TABLE datamark_source_s3 (
  source_name TEXT PRIMARY KEY NOT NULL REFERENCES datamark_source(name) ON UPDATE CASCADE ON DELETE CASCADE,
  bucket_name TEXT NOT NULL,
  medallion_tier TEXT NOT NULL,
  pattern TEXT NOT NULL
);

CREATE TABLE datamark_view (
  name TEXT PRIMARY KEY NOT NULL,
  query TEXT NOT NULL,
  source_name TEXT NOT NULL REFERENCES datamark_source(name) ON UPDATE CASCADE ON DELETE CASCADE,
  create_at INTEGER NOT NULL DEFAULT (unixepoch())
);

-- migrate:down

DROP TABLE datamark_view;
DROP TABLE datamark_source_s3;
DROP TABLE datamark_source_drive;
DROP TABLE datamark_source_github;
DROP INDEX datamark_source_name_idx;
DROP TABLE datamark_source;
DROP TABLE pages_view;
DROP TABLE pages_folder;
DROP INDEX idx_auth_session_expires_at;
DROP INDEX idx_auth_session_username;
DROP TRIGGER update_last_logged_at;
DROP TABLE auth_session;
DROP TABLE auth_user;
