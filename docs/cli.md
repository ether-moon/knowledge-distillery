# knowledge-gate CLI Interface Spec

> knowledge-gate is the sole access path to the knowledge vault (`.knowledge/vault.db`).
> Agent runtime queries, domain management, and refinement pipeline post-processing are all performed through this CLI.

## Design Principles

- **Vendor-neutral runtime / Claude-first delivery**: Agent runtime commands (§1, §2) use only `sqlite3` (pre-installed) to maintain vendor neutrality. Pipeline/management commands (§1.5, §3, §4) additionally require `jq` (for JSON processing, separate installation required). Delivery is via Claude Code Plugin, but the CLI itself can run from any agent
- **Context gateway (convention-based)**: Agents cannot directly `Read` `.knowledge/vault.db` (incidental isolation via binary format). The knowledge-gate CLI is the sole access path, maintained as a convention-based access prohibition ([Design Implementation §4.1](./design-implementation.md#41-저장-위치-및-형식) reference)
- **Domain path matching**: Resolves file paths to domains via `domain_paths`, then queries entries for those domains
- **Soft miss principle**: When there are no matching results, non-structural modifications (bug fixes, local refactoring, etc.) proceed normally while preserving existing code structure. The question protocol is invoked only for structural changes (new modules, architecture changes, pattern introductions, etc.) ([Design Implementation §7.2](./design-implementation.md#72-soft-miss-원칙))
- **Standardized DB manipulation**: The LLM decides, and the CLI manipulates the DB. Direct SQL execution is prohibited.

---

## Common

```bash
#!/usr/bin/env bash
# bin/knowledge-gate — Knowledge Vault interface
set -euo pipefail

VAULT="${KNOWLEDGE_VAULT_PATH:-$(dirname "$0")/../.knowledge/vault.db}"

if [ ! -f "$VAULT" ]; then
  echo "Knowledge vault not found at $VAULT" >&2
  exit 1
fi

# Common utility: single-quote escaping
esc() { echo "${1//\'/\'\'}"; }
```

---

## 1. Knowledge Query Commands (Agent Runtime)

Interface for agents to query relevant rules before modifying code.

### query-paths

Resolves file paths to domains and queries related active rules.

```bash
knowledge-gate query-paths <filepath>
```

**Behavior:** Generates all parent directory prefixes of filepath -> matches against `domain_paths.pattern` -> returns entries for matched domains. The global domain (pattern = `*`) is automatically included for all paths.

```bash
query_by_path() {
  local filepath
  filepath="$(esc "$1")"
  sqlite3 -json "$VAULT" "
    PRAGMA foreign_keys = ON;
    WITH RECURSIVE prefixes(p, rest) AS (
      SELECT '', '${filepath}' || '/'
      UNION ALL
      SELECT p || substr(rest, 1, instr(rest, '/')),
             substr(rest, instr(rest, '/') + 1)
      FROM prefixes WHERE rest <> '' AND instr(rest, '/') > 0
    ), filepath_prefixes AS (
      SELECT p AS prefix FROM prefixes WHERE p <> ''
    ), matched_domains AS (
      SELECT dp.domain FROM domain_paths dp
      JOIN filepath_prefixes fp ON fp.prefix = dp.pattern
      UNION
      SELECT dp.domain FROM domain_paths dp WHERE dp.pattern = '*'
    )
    SELECT DISTINCT e.id, e.type, e.claim, e.alternative, e.considerations
    FROM entries e
    JOIN entry_domains ed ON ed.entry_id = e.id
    WHERE e.status = 'active'
      AND ed.domain IN (SELECT domain FROM matched_domains);
  "
}
```

**Example:**
```bash
$ knowledge-gate query-paths src/api/auth/login.ts
[{"id":"no-ar-callback-external-api","type":"anti-pattern","claim":"...","alternative":"...","considerations":"..."}]
```

### query-domain

Directly queries active rules for a domain by domain name.

```bash
knowledge-gate query-domain <domain>
```

```bash
query_by_domain() {
  local domain
  domain="$(esc "$1")"
  sqlite3 -json "$VAULT" "
    PRAGMA foreign_keys = ON;
    SELECT DISTINCT e.id, e.type, e.claim, e.alternative, e.considerations
    FROM entries e
    JOIN entry_domains ed ON ed.entry_id = e.id
    WHERE e.status = 'active'
      AND ed.domain = '${domain}';
  "
}
```

### search

Queries keyword-matching rules via FTS5 full-text search.

```bash
knowledge-gate search <keyword>
```

```bash
search_entries() {
  local keyword
  keyword="$(esc "${1//\"/\"\"}")"
  sqlite3 -json "$VAULT" "
    SELECT e.id, e.type, e.claim, e.alternative
    FROM entries_fts fts
    JOIN entries e ON e.rowid = fts.rowid
    WHERE entries_fts MATCH '\"${keyword}\"'
      AND e.status = 'active'
    ORDER BY fts.rank;
  "
}
```

### get

Retrieves full details (including body) by entry ID.

```bash
knowledge-gate get <id>
```

```bash
get_entry() {
  local item_id
  item_id="$(esc "$1")"
  sqlite3 -json "$VAULT" "
    SELECT * FROM entries WHERE id = '${item_id}';
  "
}
```

### list

Returns a summary list of all active entries. **Reference for exploration/keyword discovery.** Used to browse the full list for relevant entries when the domain or keyword is unknown. Use `query-paths` or `query-domain` for querying rules before code modification.

```bash
knowledge-gate list
```

```bash
list_entries() {
  sqlite3 -json "$VAULT" \
    "SELECT id, type, claim FROM entries WHERE status = 'active'"
}
```

---

## 1.5. Knowledge Loading Commands

Interface for adding entries. There are two paths:

- **`add`**: Command for humans to manually add entries. Validates required fields then INSERTs into vault.db. Generates a kebab-case slug from the title as the ID.
- **`_pipeline-insert`**: Internal command exclusively for the refinement pipeline (`batch-refine`). Bulk INSERTs candidate data via JSON stdin. Not for external use.

### add

Adds an entry to the knowledge vault. Validates required fields (schema CHECK constraints + R3/R5 rules) then INSERTs into vault.db.

```bash
knowledge-gate add --type <fact|anti-pattern> --title <title> --claim <claim> --body <body> --domain <domain>[,<domain>...] [--alternative <alt>] [--considerations <text>] [--evidence <type:ref>[,<type:ref>...]]
```

**Behavior:**

1. Verify required field presence: `type`, `title`, `claim`, `body`, `domain`, `considerations`
2. Validate schema CHECK constraints:
   - If `type` is `anti-pattern`, `--alternative` is required (R3)
   - Reject if `considerations` is empty (R5)
3. Verify domain existence: error if domain is not in `domain_registry` (register new domains first with `domain-add`)
4. Output WARNING if `--evidence` is not specified (INSERT proceeds without evidence, but warns about reduced traceability)
5. Generate kebab-case slug from title (3-5 words, generated by LLM or CLI) -> INSERT `entries` + `entry_domains` + `evidence` in a **single transaction** (BEGIN/COMMIT)
6. FTS5 triggers automatically update the search index

```bash
add_entry() {
  local id type title claim body alt considerations
  # Generate kebab-case slug from title (3-5 words). Append -2, -3, etc. suffix on collision
  id="$(echo "$2" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]//g' | tr ' ' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-60)"
  # Slug collision resolution: append numeric suffix on UNIQUE constraint violation
  local base_id="$id" suffix=2
  while sqlite3 "$VAULT" "SELECT 1 FROM entries WHERE id='$(esc "$id")'" | grep -q 1; do
    id="${base_id}-${suffix}"
    suffix=$((suffix + 1))
  done
  type="$1"; title="$(esc "$2")"; claim="$(esc "$3")"; body="$(esc "$4")"
  alt="$(esc "$5")"; considerations="$(esc "$6")"
  shift 6
  local domains="$1"; shift  # comma-separated
  local evidence="${1:-}"     # comma-separated type:ref pairs

  # R3: anti-pattern requires alternative
  if [ "$type" = "anti-pattern" ] && [ -z "$alt" ]; then
    echo "ERROR: anti-pattern type requires --alternative" >&2; return 1
  fi
  # R5: considerations must not be empty
  if [ -z "$considerations" ]; then
    echo "ERROR: --considerations is required (use 'No special considerations' if none)" >&2; return 1
  fi
  # Evidence warning
  if [ -z "$evidence" ]; then
    echo "WARNING: --evidence not provided. Entry will lack traceability." >&2
  fi

  local sql="PRAGMA foreign_keys = ON; BEGIN;
    INSERT INTO entries (id, type, title, claim, body, alternative, considerations)
    VALUES ('${id}', '${type}', '${title}', '${claim}', '${body}',
            $([ -n "$alt" ] && echo "'${alt}'" || echo "NULL"), '${considerations}');"

  # entry_domains INSERT
  IFS=',' read -ra domain_arr <<< "$domains"
  for d in "${domain_arr[@]}"; do
    local esc_d
    esc_d="$(esc "$(echo "$d" | xargs)")"
    sql="${sql} INSERT INTO entry_domains(entry_id, domain) VALUES ('${id}', '${esc_d}');"
  done

  # evidence INSERT
  if [ -n "$evidence" ]; then
    IFS=',' read -ra ev_arr <<< "$evidence"
    for ev in "${ev_arr[@]}"; do
      local ev_type ev_ref
      ev_type="$(esc "${ev%%:*}")"
      ev_ref="$(esc "${ev#*:}")"
      sql="${sql} INSERT INTO evidence(entry_id, type, ref) VALUES ('${id}', '${ev_type}', '${ev_ref}');"
    done
  fi

  sql="${sql} COMMIT;"
  sqlite3 "$VAULT" "$sql"
  echo "$id"
}
```

### _pipeline-insert

Internal command for the pipeline only. Receives candidate data via JSON stdin and bulk INSERTs into vault.db. Not for external use — called only from the refinement pipeline (`batch-refine`).

```bash
echo '<json>' | knowledge-gate _pipeline-insert
```

**Input format (JSON stdin):**

```json
[
  {
    "id": "kebab-case-slug-from-title",
    "type": "fact|anti-pattern",
    "title": "...",
    "claim": "...",
    "body": "...",
    "alternative": "...|null",
    "considerations": "...",
    "domains": ["domain-a", "domain-b"],
    "evidence": [{"type": "pr", "ref": "#1234"}, {"type": "linear", "ref": "PROJ-567"}],
    "curation": [{"related_id": "existing-id", "reason": "conflict description"}]
  }
]
```

**Behavior:**

1. Parse JSON and validate required fields (including R3/R5 rules)
2. Domain auto-creation: if domains in `domains` are not in `domain_registry`, auto-create them with `knowledge-gate domain-add` (description is an auto-generated placeholder)
3. Wrap everything in a single transaction (BEGIN/COMMIT) for atomic execution:
   - `entries` INSERT
   - `entry_domains` INSERT (one row per domain)
   - `evidence` INSERT (one row per evidence item)
   - `curation_queue` INSERT (conflicting entries, if any)
4. FTS5 triggers automatically update the search index

```bash
pipeline_insert() {
  local json
  json=$(cat)  # Receive JSON array via stdin

  local sql="PRAGMA foreign_keys = ON; BEGIN;"

  # Iterate over each candidate with jq and generate SQL
  local count
  count=$(echo "$json" | jq 'length')

  for ((i=0; i<count; i++)); do
    local item
    item=$(echo "$json" | jq ".[$i]")
    local id type title claim body alt considerations
    id=$(echo "$item" | jq -r '.id')
    type=$(echo "$item" | jq -r '.type')
    title=$(echo "$item" | jq -r '.title' | sed "s/'/''/g")
    claim=$(echo "$item" | jq -r '.claim' | sed "s/'/''/g")
    body=$(echo "$item" | jq -r '.body' | sed "s/'/''/g")
    alt=$(echo "$item" | jq -r '.alternative // empty' | sed "s/'/''/g")
    considerations=$(echo "$item" | jq -r '.considerations' | sed "s/'/''/g")

    # R3: anti-pattern requires alternative
    if [ "$type" = "anti-pattern" ] && [ -z "$alt" ]; then
      echo "ERROR: anti-pattern '${id}' requires alternative" >&2; return 1
    fi

    sql="${sql}
    INSERT INTO entries (id, type, status, title, claim, body, alternative, considerations, created_at, updated_at)
    VALUES ('${id}', '${type}', 'active', '${title}', '${claim}', '${body}',
            $([ -n "$alt" ] && echo "'${alt}'" || echo "NULL"), '${considerations}',
            datetime('now'), datetime('now'));"

    # domains — auto-create if missing
    echo "$item" | jq -r '.domains[]' | while IFS= read -r domain; do
      local esc_domain
      esc_domain=$(echo "$domain" | sed "s/'/''/g")
      sql="${sql}
      INSERT OR IGNORE INTO domain_registry(domain, description, status)
      VALUES ('${esc_domain}', 'auto-created by pipeline', 'active');
      INSERT INTO entry_domains(entry_id, domain) VALUES ('${id}', '${esc_domain}');"
    done

    # evidence
    echo "$item" | jq -c '.evidence[]? // empty' | while IFS= read -r ev; do
      local ev_type ev_ref
      ev_type=$(echo "$ev" | jq -r '.type' | sed "s/'/''/g")
      ev_ref=$(echo "$ev" | jq -r '.ref' | sed "s/'/''/g")
      sql="${sql}
      INSERT INTO evidence(entry_id, type, ref) VALUES ('${id}', '${ev_type}', '${ev_ref}');"
    done

    # curation_queue
    echo "$item" | jq -c '.curation[]? // empty' | while IFS= read -r cq; do
      local cq_related cq_reason cq_id
      cq_related=$(echo "$cq" | jq -r '.related_id' | sed "s/'/''/g")
      cq_reason=$(echo "$cq" | jq -r '.reason' | sed "s/'/''/g")
      cq_id="cq-${id}-$(date +%s)"
      sql="${sql}
      INSERT INTO curation_queue(id, type, entry_id, related_id, reason, status)
      VALUES ('${cq_id}', 'conflict', '${id}', '${cq_related}', '${cq_reason}', 'pending');"
    done
  done

  sql="${sql} COMMIT;"
  sqlite3 "$VAULT" "$sql"
  echo "Inserted ${count} entries"
}
```

---

## 2. Domain Query Commands

Interface for exploring the domain registry and path mappings.

### domain-info

Queries detailed information about a domain (description, status, mapped path patterns, entry count).

```bash
knowledge-gate domain-info <domain>
```

```bash
domain_info() {
  local domain
  domain="$(esc "$1")"
  sqlite3 -json "$VAULT" "
    PRAGMA foreign_keys = ON;
    SELECT
      dr.domain,
      dr.description,
      dr.status,
      dr.created_at,
      (SELECT COUNT(DISTINCT ed.entry_id)
       FROM entry_domains ed
       JOIN entries e ON e.id = ed.entry_id
       WHERE ed.domain = dr.domain AND e.status = 'active'
      ) AS active_entries,
      (SELECT group_concat(dp.pattern, ', ')
       FROM domain_paths dp
       WHERE dp.domain = dr.domain
      ) AS patterns
    FROM domain_registry dr
    WHERE dr.domain = '${domain}';
  "
}
```

**Example:**
```bash
$ knowledge-gate domain-info payment
[{"domain":"payment","description":"Payment transaction processing","status":"active",
  "created_at":"2026-03-01","active_entries":5,
  "patterns":"app/services/payments/, app/models/payment/"}]
```

### domain-list

Queries the full domain registry filtered by status.

```bash
knowledge-gate domain-list [--status active|deprecated|all]
```

```bash
domain_list() {
  local status_filter="${1:-active}"
  if [ "$status_filter" = "all" ]; then
    sqlite3 -json "$VAULT" "
      SELECT dr.domain, dr.description, dr.status,
        (SELECT COUNT(DISTINCT ed.entry_id)
         FROM entry_domains ed JOIN entries e ON e.id = ed.entry_id
         WHERE ed.domain = dr.domain AND e.status = 'active'
        ) AS active_entries
      FROM domain_registry dr
      ORDER BY dr.status, dr.domain;
    "
  else
    local esc_status
    esc_status="$(esc "$status_filter")"
    sqlite3 -json "$VAULT" "
      SELECT dr.domain, dr.description, dr.status,
        (SELECT COUNT(DISTINCT ed.entry_id)
         FROM entry_domains ed JOIN entries e ON e.id = ed.entry_id
         WHERE ed.domain = dr.domain AND e.status = 'active'
        ) AS active_entries
      FROM domain_registry dr
      WHERE dr.status = '${esc_status}'
      ORDER BY dr.domain;
    "
  fi
}
```

### domain-resolve-path

Reverse-lookups which domains a specific file path belongs to.

```bash
knowledge-gate domain-resolve-path <filepath>
```

```bash
domain_resolve_path() {
  local filepath
  filepath="$(esc "$1")"
  sqlite3 -json "$VAULT" "
    WITH RECURSIVE prefixes(p, rest) AS (
      SELECT '', '${filepath}' || '/'
      UNION ALL
      SELECT p || substr(rest, 1, instr(rest, '/')),
             substr(rest, instr(rest, '/') + 1)
      FROM prefixes WHERE rest <> '' AND instr(rest, '/') > 0
    ), filepath_prefixes AS (
      SELECT p AS prefix FROM prefixes WHERE p <> ''
    )
    SELECT DISTINCT dp.domain, dr.description, dp.pattern AS matched_pattern
    FROM domain_paths dp
    JOIN domain_registry dr ON dr.domain = dp.domain
    JOIN filepath_prefixes fp ON fp.prefix = dp.pattern
    WHERE dr.status = 'active'
    UNION
    SELECT DISTINCT dp.domain, dr.description, dp.pattern AS matched_pattern
    FROM domain_paths dp
    JOIN domain_registry dr ON dr.domain = dp.domain
    WHERE dp.pattern = '*' AND dr.status = 'active'
    ORDER BY domain;
  "
}
```

**Example:**
```bash
$ knowledge-gate domain-resolve-path src/api/auth/login.ts
[{"domain":"api","description":"REST API layer","matched_pattern":"src/api/"},
 {"domain":"auth","description":"Authentication/authorization","matched_pattern":"src/api/auth/"},
 {"domain":"global-conventions","description":"Project-wide rules","matched_pattern":"*"}]
```

---

## 3. Domain Management Commands (Refinement Pipeline / LLM Skill)

The LLM decides, and the CLI mechanically manipulates the DB.

### domain-add

Registers a new domain in the registry.

```bash
knowledge-gate domain-add <domain> <description>
```

```bash
domain_add() {
  local domain description
  domain="$(esc "$1")"
  description="$(esc "$2")"
  sqlite3 "$VAULT" "
    PRAGMA foreign_keys = ON;
    INSERT INTO domain_registry(domain, description, status)
    VALUES ('${domain}', '${description}', 'active');
  "
  echo "Added domain: $1 (active)"
}
```

### domain-merge

Merges the source domain into the target. Transfers entries' domain assignments, transfers domain_paths, and marks the source as deprecated.

```bash
knowledge-gate domain-merge <source> <target>
```

```bash
domain_merge() {
  local source target
  source="$(esc "$1")"
  target="$(esc "$2")"
  sqlite3 "$VAULT" "
    PRAGMA foreign_keys = ON;
    BEGIN;
    -- Transfer entry domain assignments: source -> target (ignore duplicates)
    INSERT OR IGNORE INTO entry_domains(entry_id, domain)
    SELECT entry_id, '${target}' FROM entry_domains WHERE domain = '${source}';
    DELETE FROM entry_domains WHERE domain = '${source}';

    -- Transfer domain_paths (ignore duplicates)
    INSERT OR IGNORE INTO domain_paths(domain, pattern)
    SELECT '${target}', pattern FROM domain_paths WHERE domain = '${source}';
    DELETE FROM domain_paths WHERE domain = '${source}';

    -- Deprecate source
    UPDATE domain_registry SET status = 'deprecated' WHERE domain = '${source}';
    COMMIT;
  "
  echo "Merged: $1 → $2"
}
```

### domain-split

Splits a source domain into two domains. Entries are assigned to both sides, and precise reassignment is performed in subsequent curation.

```bash
knowledge-gate domain-split <source> <new-a> <desc-a> <new-b> <desc-b>
```

After splitting, the source's entries are **assigned to both new-a and new-b**. Precise reassignment is performed in subsequent LLM curation or `domain-report` review.

1. Redistribute source's domain_paths to new-a, new-b (specified via arguments or pre-set by LLM using `domain-paths-set`)
2. Assign both new-a and new-b domains to all entries of source
3. Mark source as deprecated
4. Remove unnecessary domains in subsequent LLM curation

```bash
domain_split() {
  local source new_a desc_a new_b desc_b
  source="$(esc "$1")"
  new_a="$(esc "$2")"
  desc_a="$(esc "$3")"
  new_b="$(esc "$4")"
  desc_b="$(esc "$5")"
  sqlite3 "$VAULT" "
    PRAGMA foreign_keys = ON;
    BEGIN;
    -- Register new domains
    INSERT INTO domain_registry(domain, description, status)
    VALUES ('${new_a}', '${desc_a}', 'active'),
           ('${new_b}', '${desc_b}', 'active');

    -- Assign both domains to all source entries
    INSERT OR IGNORE INTO entry_domains(entry_id, domain)
    SELECT ed.entry_id, '${new_a}' FROM entry_domains ed
    WHERE ed.domain = '${source}';
    INSERT OR IGNORE INTO entry_domains(entry_id, domain)
    SELECT ed.entry_id, '${new_b}' FROM entry_domains ed
    WHERE ed.domain = '${source}';

    -- Clean up source
    DELETE FROM entry_domains WHERE domain = '${source}';
    DELETE FROM domain_paths WHERE domain = '${source}';
    UPDATE domain_registry SET status = 'deprecated' WHERE domain = '${source}';
    COMMIT;
  "
  echo "Split: $1 → $2, $4"
  echo "[ACTION REQUIRED] Set path mappings for the new domains:"
  echo "  knowledge-gate domain-paths-set '${new_a}' <patterns...>"
  echo "  knowledge-gate domain-paths-set '${new_b}' <patterns...>"
}
```

### domain-deprecate

Deprecates a domain. If entries remain, a migration target must be specified.

```bash
knowledge-gate domain-deprecate <domain> [--merge-into <target>]
```

When `--merge-into` is specified, behaves identically to `domain-merge`. When not specified, only allowed if the domain has no active entries.

### domain-paths-set

Sets path patterns for a domain (replaces existing patterns).

```bash
knowledge-gate domain-paths-set <domain> <pattern> [<pattern>...]
```

```bash
domain_paths_set() {
  local domain sql
  domain="$(esc "$1")"
  shift
  sql="PRAGMA foreign_keys = ON; BEGIN; DELETE FROM domain_paths WHERE domain = '${domain}';"
  for pattern in "$@"; do
    local esc_pattern
    esc_pattern="$(esc "$pattern")"
    sql="${sql} INSERT INTO domain_paths(domain, pattern) VALUES ('${domain}', '${esc_pattern}');"
  done
  sql="${sql} COMMIT;"
  sqlite3 "$VAULT" "${sql}"
  echo "Set patterns for ${domain}: $*"
}
```

### domain-paths-add / domain-paths-remove

Add or remove individual patterns.

```bash
knowledge-gate domain-paths-add <domain> <pattern>
knowledge-gate domain-paths-remove <domain> <pattern>
```

---

## 4. Domain Report Commands

Diagnoses domain status after refinement batches and surfaces items needing adjustment.
Serves as input for the LLM domain setup Skill and as the basis for notifying humans.

### domain-report

```bash
knowledge-gate domain-report
```

**Density evaluation criteria (quantitative thresholds):**

| Criterion | Condition | Verdict |
|---|---|---|
| Overcrowded | Active entries > N in a single domain (initial N=15) | Split candidate |
| Sparse | Active entries <= 2 in a domain | Merge candidate |
| Orphan | 0 entries + 30 days since creation | Deprecation candidate |
| Underutilized new | 30 days since creation + active entries <= 1 | Merge/deprecation candidate |
| Overly broad pattern | A single pattern matches 30%+ of all files | Requires human review |
| Uncovered pattern | 20%+ of recent batch PR diff files have no domain resolution | Patterns need to be added (reported by batch-refine, not CLI) |
| Structural mismatch | No corresponding domain for top-2 depth directories | New domain candidate |

Thresholds (N, 30 days, 30%, 20%) are adjusted based on project scale. Start loose initially and calibrate with accumulated data.

**Output format:**

```
$ knowledge-gate domain-report

=== Domain Registry (14 active, 1 deprecated) ===

  [!] SPLIT CANDIDATE (entries > 15):
      backend  — 23 entries, patterns: src/api/, src/services/

  [!] MERGE CANDIDATE (entries ≤ 2):
      logging  — 1 entry
      monitoring — 2 entries

  [!] ORPHAN (0 entries, 45 days):
      legacy-admin  — deprecated candidate

=== domain_paths Coverage ===
  Total patterns: 34
  Broadest pattern: src/ (matches 45% of repo)  [WARNING > 30%]

=== Action Items ===
  1. Consider splitting: backend
  2. Consider merging: logging + monitoring → observability?
  3. Deprecate: legacy-admin
```

**Implementation note:** The current CLI implementation diagnoses repository-structure mismatch and domain density from vault/repo state. Batch-specific uncovered-pattern detection uses recent PR diff context, so it is reported by `batch-refine`, not `domain-report`.

```bash
domain_report() {
  echo "=== Domain Registry ==="
  sqlite3 "$VAULT" "
    SELECT
      (SELECT COUNT(*) FROM domain_registry WHERE status='active') AS active,
      (SELECT COUNT(*) FROM domain_registry WHERE status='deprecated') AS deprecated;
  "

  echo ""
  echo "[!] SPLIT CANDIDATES (entries > 15):"
  sqlite3 "$VAULT" "
    SELECT dr.domain, sub.cnt
    FROM domain_registry dr
    JOIN (
      SELECT ed.domain, COUNT(DISTINCT ed.entry_id) AS cnt
      FROM entry_domains ed
      JOIN entries e ON e.id = ed.entry_id
      WHERE e.status = 'active'
      GROUP BY ed.domain
    ) sub ON sub.domain = dr.domain
    WHERE dr.status = 'active' AND sub.cnt > 15
    ORDER BY sub.cnt DESC;
  "

  echo ""
  echo "[!] MERGE CANDIDATES (entries <= 2):"
  sqlite3 "$VAULT" "
    SELECT dr.domain, sub.cnt
    FROM domain_registry dr
    JOIN (
      SELECT ed.domain, COUNT(DISTINCT ed.entry_id) AS cnt
      FROM entry_domains ed
      JOIN entries e ON e.id = ed.entry_id
      WHERE e.status = 'active'
      GROUP BY ed.domain
    ) sub ON sub.domain = dr.domain
    WHERE dr.status = 'active' AND sub.cnt <= 2
    ORDER BY sub.cnt;
  "

  echo ""
  echo "[!] ORPHAN CANDIDATES (0 entries, 30+ days):"
  sqlite3 "$VAULT" "
    SELECT dr.domain, dr.created_at
    FROM domain_registry dr
    WHERE dr.status = 'active'
      AND (SELECT COUNT(*) FROM entry_domains ed JOIN entries e ON e.id=ed.entry_id
           WHERE ed.domain=dr.domain AND e.status='active') = 0
      AND julianday('now') - julianday(dr.created_at) > 30;
  "
}
```

---

## 5. Agent Skill Template

The CLI and data are shared across all agents; only the Skill file is provided per agent.

```markdown
# knowledge-gate Skill Example (for Claude Code)

---
description: Queries related rules from the knowledge vault before code modification.
  Must be used when modifying files or making structural changes.
---

## When to Use

- Before modifying code files
- Before creating new files/modules
- When performing tasks that require architectural decisions

## Query Protocol

### When modifying a single file
bin/knowledge-gate query-paths "<file path to modify>"

### When modifying multiple files (PR-scale changes)
# 1. Identify related domains (a few representative files suffice)
bin/knowledge-gate domain-resolve-path "<file path>"
# 2. Query rules by domain (efficient, no duplicates)
bin/knowledge-gate query-domain "<domain name>"

### Search by keyword (when path matching yields no results)
bin/knowledge-gate search "<keyword>"

### When detailed rule inspection is needed
bin/knowledge-gate get "<entry ID>"

### When the domain/keyword is unknown (exploration reference)
bin/knowledge-gate list
# -> Summary list of all active entries. Identify relevant domains or keywords here,
#    then perform precise queries with query-paths / query-domain / search

### Domain lookup
bin/knowledge-gate domain-info "<domain name>"
bin/knowledge-gate domain-resolve-path "<file path>"

## Behavioral Rules

- If knowledge-gate returns no results:
  - Non-structural modifications (bug fixes, local refactoring, etc.): preserve existing code structure and proceed
  - Structural changes (new modules, architecture changes, pattern introductions, etc.): invoke the question protocol ([§7.3](./design-implementation.md#73-질문-프로토콜))
- If a MUST-NOT rule exists: comply unconditionally. Follow the alternative
- If Stop Conditions apply: confirm with a human before proceeding
- Do not directly read files in the .knowledge/ directory
```

---

## 6. Domain Derivation (LLM-based)

The flow in which the refinement pipeline creates entries in the `entry_domains` table. Domain assignment is **decided by the LLM**. The path patterns in `domain_paths` are reference material, not mechanical matching rules — path matching alone cannot determine cross-cutting concerns, business context, or appropriate levels of abstraction.

```
PR change context (commit messages, review discussions, Linear issues)
+ Existing domain registry (domain_registry)
+ Path pattern reference (domain_paths)
    ↓
  The extraction LLM makes a comprehensive judgment to assign domains
    e.g.: Payment service refactoring PR → domain: payment
    e.g.: AR callback failure fix PR → domain: payment, activerecord
    ↓
  INSERT into entry_domains table with assigned domains
    ↓
  When no matching domain exists:
    → LLM proposes {name, description, suggested_patterns}
    → Applied via knowledge-gate domain-add + domain-paths-set
    → Merged/deprecated if unnecessary in subsequent domain review/reorganization (refinement batch step 8, §3.1 B)
```

**Domain definition guidelines (included in the extraction prompt):**

- **Granularity:** The unit at which a team makes independent decisions. "payment" is appropriate, but over-splitting into "payment-refund" and "payment-charge" should be avoided
- **Cross-cutting concerns:** Rules not confined to a specific directory (security policies, testing practices, error handling, etc.) are classified as technical cross-cutting domains
- **Naming convention:** Lowercase kebab-case, distinguishing business domains from technical domains (e.g., `payment` vs `activerecord`)

After each refinement batch, the domain setup references `domain-report` results to review and update both the domain registry and `domain_paths` patterns.

---

## 7. Utility Commands

Auxiliary commands for operations and maintenance.

### migrate

Performs schema migration based on PRAGMA user_version.

```bash
knowledge-gate migrate
```

**Behavior:**

1. Query `PRAGMA user_version` -> check current schema version
2. Sequentially execute scripts after the current version from the migration script directory (`schema/migrations/`)
3. Update `PRAGMA user_version = N` after each script execution
4. Wrap the entire process in a single transaction (rollback on failure)

```bash
migrate_vault() {
  local current_version
  current_version=$(sqlite3 "$VAULT" "PRAGMA user_version;")
  local migration_dir
  migration_dir="$(dirname "$0")/../schema/migrations"

  if [ ! -d "$migration_dir" ]; then
    echo "No migrations directory found" >&2; return 0
  fi

  local sql="BEGIN;"
  for f in "$migration_dir"/*.sql; do
    local version
    version=$(basename "$f" .sql | grep -oE '^[0-9]+')
    if [ "$version" -gt "$current_version" ]; then
      sql="${sql} $(cat "$f") PRAGMA user_version = ${version};"
    fi
  done
  sql="${sql} COMMIT;"
  sqlite3 "$VAULT" "$sql"
  echo "Migrated from version ${current_version} to $(sqlite3 "$VAULT" "PRAGMA user_version;")"
}
```

### curate

Interactively reviews and resolves pending items in `curation_queue` sequentially.

```bash
knowledge-gate curate
```

**Behavior:**

1. Query items with `status = 'pending'` from `curation_queue`
2. Display conflict details for each item (existing entry vs new entry)
3. User selects an action:
   - `keep-both` — Keep both active, mark queue item as resolved
   - `keep-existing` — Mark new entry as superseded
   - `keep-new` — Mark existing entry as superseded
   - `archive-both` — Mark both as superseded
   - `skip` — Skip this item (remains pending)
   - `quit` — Exit immediately

```bash
curate_queue() {
  local items
  items=$(sqlite3 -json "$VAULT" "
    SELECT cq.id, cq.type, cq.entry_id, cq.related_id, cq.reason,
           e1.title AS entry_title, e1.claim AS entry_claim,
           e2.title AS related_title, e2.claim AS related_claim
    FROM curation_queue cq
    LEFT JOIN entries e1 ON e1.id = cq.entry_id
    LEFT JOIN entries e2 ON e2.id = cq.related_id
    WHERE cq.status = 'pending'
    ORDER BY cq.created_at;
  ")

  local count
  count=$(echo "$items" | jq 'length')
  if [ "$count" -eq 0 ]; then
    echo "No pending curation items."; return 0
  fi

  echo "=== Curation Queue: ${count} pending items ==="
  echo "$items" | jq -c '.[]' | while IFS= read -r item; do
    local cq_id entry_id related_id reason entry_title related_title
    cq_id=$(echo "$item" | jq -r '.id')
    entry_id=$(echo "$item" | jq -r '.entry_id')
    related_id=$(echo "$item" | jq -r '.related_id')
    reason=$(echo "$item" | jq -r '.reason')
    entry_title=$(echo "$item" | jq -r '.entry_title')
    related_title=$(echo "$item" | jq -r '.related_title')

    echo ""
    echo "--- ${cq_id} ---"
    echo "Type: conflict"
    echo "Reason: ${reason}"
    echo "  [NEW]      ${entry_id}: ${entry_title}"
    echo "  [EXISTING] ${related_id}: ${related_title}"
    echo ""
    echo "Action? [keep-both / keep-existing / keep-new / archive-both / skip / quit]"
    read -r action

    case "$action" in
      keep-both)
        sqlite3 "$VAULT" "UPDATE curation_queue SET status='resolved' WHERE id='$(esc "$cq_id")';"
        echo "Resolved: both kept." ;;
      keep-existing)
        sqlite3 "$VAULT" "BEGIN; UPDATE entries SET status='superseded', archived_at=datetime('now') WHERE id='$(esc "$entry_id")'; UPDATE curation_queue SET status='resolved' WHERE id='$(esc "$cq_id")'; COMMIT;"
        echo "Resolved: new entry superseded." ;;
      keep-new)
        sqlite3 "$VAULT" "BEGIN; UPDATE entries SET status='superseded', archived_at=datetime('now') WHERE id='$(esc "$related_id")'; UPDATE curation_queue SET status='resolved' WHERE id='$(esc "$cq_id")'; COMMIT;"
        echo "Resolved: existing entry superseded." ;;
      archive-both)
        sqlite3 "$VAULT" "BEGIN; UPDATE entries SET status='superseded', archived_at=datetime('now') WHERE id IN ('$(esc "$entry_id")','$(esc "$related_id")'); UPDATE curation_queue SET status='resolved' WHERE id='$(esc "$cq_id")'; COMMIT;"
        echo "Resolved: both archived." ;;
      skip) echo "Skipped." ;;
      quit) echo "Exiting curation."; return 0 ;;
      *) echo "Unknown action, skipping." ;;
    esac
  done
}
```

---

## Command Summary

| Command | Purpose | Used By |
|---|---|---|
| `query-paths <filepath>` | Query related rules by file path | Agent |
| `query-domain <domain>` | Query rules by domain | Agent |
| `search <keyword>` | FTS5 keyword search | Agent |
| `get <id>` | Retrieve full entry details | Agent |
| `list` | Summary list of active entries (for exploration/keyword discovery) | Agent / Human |
| `add` | Add entry. Required field validation (schema CHECK + R3/R5) + vault.db INSERT | Refinement pipeline / Human |
| `domain-info <domain>` | Domain details (description, patterns, entry count) | Agent / Human |
| `domain-list [--status]` | Query domain registry | Agent / Human |
| `domain-resolve-path <filepath>` | Reverse-lookup file to domain | Agent / Human |
| `domain-add` | Register domain | Refinement pipeline |
| `domain-merge` | Merge domains (including entry transfer) | Refinement pipeline |
| `domain-split` | Split domain (including entry reassignment) | Refinement pipeline |
| `domain-deprecate` | Deprecate domain | Refinement pipeline |
| `domain-paths-set` | Bulk set domain path patterns | Refinement pipeline |
| `domain-paths-add` | Add path pattern | Refinement pipeline |
| `domain-paths-remove` | Remove path pattern | Refinement pipeline |
| `domain-report` | Domain status diagnosis + surface adjustment candidates | Refinement pipeline / Human |
| `_pipeline-insert` | Pipeline-only bulk INSERT (JSON stdin) | Refinement pipeline (internal) |
| `migrate` | PRAGMA user_version-based schema migration | Administrator |
| `curate` | Interactive curation_queue resolution | Human |
