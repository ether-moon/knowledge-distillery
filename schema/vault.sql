PRAGMA user_version = 1;
PRAGMA foreign_keys = ON;

-- Knowledge entries (Fact / Anti-Pattern)
CREATE TABLE entries (
  id              TEXT PRIMARY KEY,
  type            TEXT NOT NULL CHECK(type IN ('fact', 'anti-pattern')),
  status          TEXT NOT NULL DEFAULT 'active'
                  CHECK(status IN ('active', 'archived')),
  title           TEXT NOT NULL,
  claim           TEXT NOT NULL,
  body            TEXT NOT NULL,
  alternative     TEXT,
  considerations  TEXT NOT NULL,
  archived_at     TEXT,
  archive_reason  TEXT,
  created_at      TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
  CHECK(type != 'anti-pattern' OR alternative IS NOT NULL),
  CHECK(
    (status = 'active' AND archived_at IS NULL AND archive_reason IS NULL) OR
    (status = 'archived' AND archived_at IS NOT NULL AND length(trim(COALESCE(archive_reason, ''))) > 0)
  )
);

-- Domain dictionary (controlled vocabulary)
CREATE TABLE domain_registry (
  domain      TEXT PRIMARY KEY,
  description TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'active'
              CHECK(status IN ('active', 'deprecated')),
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Domain-path mapping (1-depth hierarchy)
CREATE TABLE domain_paths (
  domain  TEXT NOT NULL REFERENCES domain_registry(domain),
  pattern TEXT NOT NULL,
  PRIMARY KEY (domain, pattern)
);

-- Entry-domain mapping
CREATE TABLE entry_domains (
  entry_id TEXT NOT NULL REFERENCES entries(id),
  domain   TEXT NOT NULL REFERENCES domain_registry(domain),
  PRIMARY KEY (entry_id, domain)
);

-- Evidence links
CREATE TABLE evidence (
  entry_id TEXT NOT NULL REFERENCES entries(id),
  type     TEXT NOT NULL CHECK(type IN ('pr', 'linear', 'slack', 'greptile', 'memento')),
  ref      TEXT NOT NULL CHECK(length(trim(ref)) > 0),
  PRIMARY KEY (entry_id, type, ref)
);

-- Human decision queue (entries requiring human intervention)
CREATE TABLE curation_queue (
  id           TEXT PRIMARY KEY,
  type         TEXT NOT NULL,
  entry_id     TEXT NOT NULL REFERENCES entries(id),
  related_id   TEXT REFERENCES entries(id),
  reason       TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending'
               CHECK(status IN ('pending', 'resolved')),
  resolved_at  TEXT,
  created_at   TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Full-text search (FTS5)
CREATE VIRTUAL TABLE entries_fts USING fts5(
  title, claim, body,
  content='entries',
  content_rowid='rowid'
);

-- FTS5 sync triggers
CREATE TRIGGER entries_ai AFTER INSERT ON entries BEGIN
  INSERT INTO entries_fts(rowid, title, claim, body)
  VALUES (new.rowid, new.title, new.claim, new.body);
END;

CREATE TRIGGER entries_ad AFTER DELETE ON entries BEGIN
  INSERT INTO entries_fts(entries_fts, rowid, title, claim, body)
  VALUES ('delete', old.rowid, old.title, old.claim, old.body);
END;

CREATE TRIGGER entries_au AFTER UPDATE ON entries BEGIN
  INSERT INTO entries_fts(entries_fts, rowid, title, claim, body)
  VALUES ('delete', old.rowid, old.title, old.claim, old.body);
  INSERT INTO entries_fts(rowid, title, claim, body)
  VALUES (new.rowid, new.title, new.claim, new.body);
END;

-- Indexes
CREATE INDEX entries_status_idx ON entries(status);
CREATE INDEX entry_domains_domain_idx ON entry_domains(domain, entry_id);
CREATE INDEX domain_paths_pattern_idx ON domain_paths(pattern);
CREATE INDEX curation_queue_status_idx ON curation_queue(status, created_at);
