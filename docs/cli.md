# knowledge-gate CLI 인터페이스 스펙

> knowledge-gate는 지식 금고(`.knowledge/vault.db`)의 유일한 접근 경로다.
> 에이전트 런타임 쿼리, 도메인 관리, 정제 파이프라인 후처리를 모두 이 CLI를 통해 수행한다.

## 설계 원칙

- **벤더 중립**: 에이전트 런타임 커맨드(§1, §2)는 `sqlite3`(사전 설치)만 사용. 파이프라인/관리 커맨드(§1.5, §3, §4)는 `jq`를 추가로 요구한다 (JSON 처리용, 별도 설치 필요)
- **컨텍스트 관문 강제**: 에이전트는 `.knowledge/vault.db`를 직접 `Read`할 수 없다 (바이너리). knowledge-gate CLI만이 유일한 접근 경로 ([설계 구현 §4.1](./design-implementation.md#41-저장-위치-및-형식) 참조)
- **도메인 경로 매칭**: 파일 경로를 `domain_paths`로 도메인에 해소한 후, 해당 도메인의 entries를 조회
- **Miss handling**: 매칭 결과가 없으면 추론하지 않고 질문 프로토콜을 즉시 발동 ([설계 구현 §7.3](./design-implementation.md#73-질문-프로토콜))
- **규격화된 DB 조작**: LLM이 판단하고, CLI가 DB를 조작한다. 직접 SQL 실행 금지.

---

## 공통

```bash
#!/usr/bin/env bash
# bin/knowledge-gate — Knowledge Vault interface
set -euo pipefail

VAULT="${KNOWLEDGE_VAULT_PATH:-$(dirname "$0")/../.knowledge/vault.db}"

if [ ! -f "$VAULT" ]; then
  echo "Knowledge vault not found at $VAULT" >&2
  exit 1
fi

# 공통 유틸: single-quote 이스케이핑
esc() { echo "${1//\'/\'\'}"; }
```

---

## 1. 지식 조회 커맨드 (에이전트 런타임용)

에이전트가 코드 수정 전 관련 규칙을 조회하는 인터페이스.

### query-paths

파일 경로를 도메인으로 해소하여 관련 활성 규칙을 조회한다.

```bash
knowledge-gate query-paths <filepath>
```

**동작:** filepath의 모든 상위 디렉토리 prefix를 생성 → `domain_paths.pattern`과 매칭 → 해당 도메인의 entries 반환

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
    )
    SELECT DISTINCT e.id, e.type, e.claim, e.alternative, e.considerations
    FROM entries e
    JOIN entry_domains ed ON ed.entry_id = e.id
    WHERE e.status = 'active'
      AND ed.domain IN (SELECT domain FROM matched_domains);
  "
}
```

**예시:**
```bash
$ knowledge-gate query-paths src/api/auth/login.ts
[{"id":"no-ar-callback-external-api","type":"anti-pattern","claim":"...","alternative":"...","considerations":"..."}]
```

### query-domain

도메인 이름으로 해당 도메인의 활성 규칙을 직접 조회한다.

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

FTS5 전문 검색으로 키워드 매칭 규칙을 조회한다.

```bash
knowledge-gate search <keyword>
```

```bash
search_entries() {
  local keyword
  keyword="$(esc "$1")"
  sqlite3 -json "$VAULT" "
    SELECT e.id, e.type, e.claim, e.alternative
    FROM entries_fts fts
    JOIN entries e ON e.rowid = fts.rowid
    WHERE entries_fts MATCH '${keyword}'
      AND e.status = 'active'
    ORDER BY fts.rank;
  "
}
```

### get

항목 ID로 전체 상세(body 포함)를 조회한다.

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

모든 활성 항목의 요약 목록을 반환한다. **탐색/키워드 발견용 레퍼런스.** 도메인이나 키워드를 모를 때 전체 목록에서 관련 항목을 탐색하는 용도다. 코드 수정 전 규칙 조회에는 `query-paths` 또는 `query-domain`을 사용할 것.

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

## 1.5. 지식 적재 커맨드

항목 추가를 위한 인터페이스. 수동 적재(Phase 1)와 정제 파이프라인 적재 모두에서 사용한다.

### add

지식 금고에 항목을 추가한다. 필수 필드 검증(스키마 CHECK 제약 + R3/R5 규칙)을 수행한 후 vault.db에 INSERT한다.

```bash
knowledge-gate add --type <fact|anti-pattern> --title <title> --claim <claim> --body <body> --domain <domain>[,<domain>...] [--alternative <alt>] [--considerations <text>] [--evidence <type:ref>[,<type:ref>...]]
```

**동작:**

1. 필수 필드 존재 확인: `type`, `title`, `claim`, `body`, `domain`, `considerations`
2. 스키마 CHECK 제약 검증:
   - `type`이 `anti-pattern`이면 `--alternative` 필수 (R3)
   - `considerations`가 비어있으면 거부 (R5)
3. 도메인 존재 확인: `domain_registry`에 없는 도메인이면 에러 (신규 도메인은 `domain-add`로 먼저 등록)
4. `--evidence` 미지정 시 WARNING 출력 (evidence 없이도 INSERT는 진행되지만, 추적 가능성이 떨어짐을 경고)
5. UUID 자동 생성 → `entries` + `entry_domains` + `evidence`를 **단일 트랜잭션**(BEGIN/COMMIT)으로 INSERT
6. FTS5 트리거가 자동으로 검색 인덱스 갱신

```bash
add_entry() {
  local id type title claim body alt considerations
  id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
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
    echo "ERROR: --considerations is required (use '특별한 고려사항 없음' if none)" >&2; return 1
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

파이프라인 전용 내부 커맨드. JSON stdin으로 후보 데이터를 받아 vault.db에 일괄 INSERT한다. 외부 사용 금지 — 정제 파이프라인(`batch-refine`)에서만 호출한다.

```bash
echo '<json>' | knowledge-gate _pipeline-insert
```

**입력 형식 (JSON stdin):**

```json
[
  {
    "id": "uuid",
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

**동작:**

1. JSON 파싱 및 필수 필드 검증 (R3/R5 규칙 포함)
2. 도메인 auto-creation: `domains`에 포함된 도메인이 `domain_registry`에 없으면 `knowledge-gate domain-add`로 자동 생성 (description은 auto-generated placeholder)
3. 전체를 단일 트랜잭션(BEGIN/COMMIT)으로 래핑하여 원자적 실행:
   - `entries` INSERT
   - `entry_domains` INSERT (도메인별 1행)
   - `evidence` INSERT (증거별 1행)
   - `curation_queue` INSERT (충돌 항목, 있는 경우)
4. FTS5 트리거가 자동으로 검색 인덱스 갱신

```bash
pipeline_insert() {
  local json
  json=$(cat)  # stdin으로 JSON 배열 수신

  local sql="PRAGMA foreign_keys = ON; BEGIN;"

  # jq로 각 후보를 순회하며 SQL 생성
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

## 2. 도메인 조회 커맨드

도메인 레지스트리와 경로 매핑을 탐색하는 인터페이스.

### domain-info

도메인의 상세 정보(설명, 상태, 매핑된 경로 패턴, 항목 수)를 조회한다.

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

**예시:**
```bash
$ knowledge-gate domain-info payment
[{"domain":"payment","description":"결제 트랜잭션 처리","status":"active",
  "created_at":"2026-03-01","active_entries":5,
  "patterns":"app/services/payments/, app/models/payment/"}]
```

### domain-list

전체 도메인 레지스트리를 상태별로 조회한다.

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

특정 파일 경로가 어떤 도메인에 속하는지 역조회한다.

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
    ORDER BY dp.domain;
  "
}
```

**예시:**
```bash
$ knowledge-gate domain-resolve-path src/api/auth/login.ts
[{"domain":"auth","description":"인증/인가","matched_pattern":"src/api/auth/"},
 {"domain":"api","description":"REST API 레이어","matched_pattern":"src/api/"}]
```

---

## 3. 도메인 관리 커맨드 (정제 파이프라인 / LLM Skill용)

LLM이 판단하고, CLI가 DB를 기계적으로 조작한다.

### domain-add

새 도메인을 레지스트리에 등록한다.

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

source 도메인을 target에 병합한다. entries 도메인 이관, domain_paths 이관, source를 deprecated 처리.

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
    -- entries 도메인 이관: source → target (중복 무시)
    INSERT OR IGNORE INTO entry_domains(entry_id, domain)
    SELECT entry_id, '${target}' FROM entry_domains WHERE domain = '${source}';
    DELETE FROM entry_domains WHERE domain = '${source}';

    -- domain_paths 이관 (중복 무시)
    INSERT OR IGNORE INTO domain_paths(domain, pattern)
    SELECT '${target}', pattern FROM domain_paths WHERE domain = '${source}';
    DELETE FROM domain_paths WHERE domain = '${source}';

    -- source 폐기
    UPDATE domain_registry SET status = 'deprecated' WHERE domain = '${source}';
    COMMIT;
  "
  echo "Merged: $1 → $2"
}
```

### domain-split

source 도메인을 두 도메인으로 분할한다. entries는 양쪽에 부여하고 정밀 재배정은 이후 큐레이션에서 수행한다.

```bash
knowledge-gate domain-split <source> <new-a> <desc-a> <new-b> <desc-b>
```

분할 후 source의 entries는 new-a, new-b **양쪽 모두에 도메인을 부여**한다. 정밀한 재배정은 이후 LLM 큐레이션 또는 `domain-report` 리뷰에서 수행한다.

1. source의 domain_paths를 new-a, new-b에 재배분 (인자로 지정하거나 LLM이 사전에 `domain-paths-set`으로 설정)
2. source의 모든 entries에 new-a, new-b 양쪽 도메인 부여
3. source를 deprecated 처리
4. 이후 LLM 큐레이션에서 불필요한 도메인 제거

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
    -- 새 도메인 등록
    INSERT INTO domain_registry(domain, description, status)
    VALUES ('${new_a}', '${desc_a}', 'active'),
           ('${new_b}', '${desc_b}', 'active');

    -- source entries에 양쪽 도메인 모두 부여
    INSERT OR IGNORE INTO entry_domains(entry_id, domain)
    SELECT ed.entry_id, '${new_a}' FROM entry_domains ed
    WHERE ed.domain = '${source}';
    INSERT OR IGNORE INTO entry_domains(entry_id, domain)
    SELECT ed.entry_id, '${new_b}' FROM entry_domains ed
    WHERE ed.domain = '${source}';

    -- source 정리
    DELETE FROM entry_domains WHERE domain = '${source}';
    DELETE FROM domain_paths WHERE domain = '${source}';
    UPDATE domain_registry SET status = 'deprecated' WHERE domain = '${source}';
    COMMIT;
  "
  echo "Split: $1 → $2, $4"
  echo "[ACTION REQUIRED] 새 도메인의 경로 매핑을 설정하세요:"
  echo "  knowledge-gate domain-paths-set '${new_a}' <패턴들...>"
  echo "  knowledge-gate domain-paths-set '${new_b}' <패턴들...>"
}
```

### domain-deprecate

도메인을 폐기한다. entries가 남아있으면 이관 대상을 지정해야 한다.

```bash
knowledge-gate domain-deprecate <domain> [--merge-into <target>]
```

`--merge-into` 지정 시 `domain-merge`와 동일 동작. 미지정 시 해당 도메인에 active entries가 없을 때만 허용.

### domain-paths-set

도메인의 경로 패턴을 설정한다 (기존 패턴 교체).

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

개별 패턴을 추가하거나 제거한다.

```bash
knowledge-gate domain-paths-add <domain> <pattern>
knowledge-gate domain-paths-remove <domain> <pattern>
```

---

## 4. 도메인 리포트 커맨드

정제 배치 후 도메인 상태를 진단하고 조정 필요 항목을 표면화한다.
LLM 도메인 셋업 Skill의 입력이자, 인간에게 노티스하는 근거.

### domain-report

```bash
knowledge-gate domain-report
```

**밀도 평가 기준 (정량 임곗값):**

| 기준 | 조건 | 판정 |
|---|---|---|
| 과밀 | 단일 도메인에 active entries > N개 (초기 N=15) | 분할 후보 |
| 과소 | 도메인에 active entries ≤ 2개 | 병합 후보 |
| 고아 | entries 0개 + 생성 후 30일 경과 | 폐기 후보 |
| 신규 저활용 | 생성 후 30일 경과 + active entries ≤ 1개 | 병합/폐기 후보 |
| 패턴 과대 | 단일 패턴이 전체 파일의 30%+ 매칭 | 인간 확인 필요 |
| 패턴 미커버 | 최근 배치 PR diff 파일 중 20%+가 도메인 미해소 | 패턴 추가 필요 |
| 구조 불일치 | 디렉토리 top-2 depth에 대응 도메인 없음 | 신규 도메인 후보 |

임곗값(N, 30일, 30%, 20%)은 프로젝트 규모에 따라 조정. 초기에는 느슨하게 시작하고 축적 데이터로 보정.

**출력 형식:**

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

**구현 참고:** 패턴 과대/미커버 판정은 리포지토리의 실제 파일 목록이 필요하므로, `domain-report`는 `git ls-files` 또는 `find` 출력을 입력으로 받거나, 실행 시점에 직접 스캔한다.

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

## 5. 에이전트 Skill 템플릿

CLI와 데이터는 모든 에이전트가 공유하고, Skill 파일만 에이전트별로 제공한다.

```markdown
# knowledge-gate Skill 예시 (Claude Code용)

---
description: 코드 수정 전 지식 금고에서 관련 규칙을 조회한다.
  파일을 수정하거나 구조적 변경을 할 때 반드시 사용할 것.
---

## 사용 시점

- 코드 파일을 수정하기 전
- 새 파일/모듈을 생성하기 전
- 아키텍처 결정이 필요한 작업 시

## 쿼리 프로토콜

### 단일 파일 수정 시
bin/knowledge-gate query-paths "<수정할 파일 경로>"

### 다중 파일 수정 시 (PR 규모 변경)
# 1. 관련 도메인 확인 (대표 파일 몇 개로 충분)
bin/knowledge-gate domain-resolve-path "<파일 경로>"
# 2. 도메인 단위로 규칙 조회 (중복 없이 효율적)
bin/knowledge-gate query-domain "<도메인명>"

### 키워드로 검색 (경로 매칭이 없을 때)
bin/knowledge-gate search "<키워드>"

### 상세 규칙 확인이 필요할 때
bin/knowledge-gate get "<항목 ID>"

### 도메인/키워드를 모를 때 (탐색용 레퍼런스)
bin/knowledge-gate list
# → 전체 활성 항목 요약 목록. 여기서 관련 도메인이나 키워드를 파악한 후
#   query-paths / query-domain / search로 정밀 조회

### 도메인 확인
bin/knowledge-gate domain-info "<도메인명>"
bin/knowledge-gate domain-resolve-path "<파일 경로>"

## 행동 규칙

- knowledge-gate 결과가 없으면:
  - 비구조적 수정(버그 수정, 로컬 리팩토링 등): 기존 코드 구조를 유지하고 진행
  - 구조적 변경(새 모듈, 아키텍처 변경, 패턴 도입 등): 질문 프로토콜 발동 ([§7.3](./design-implementation.md#73-질문-프로토콜))
- MUST-NOT 규칙이 있으면: 반드시 준수. alternative를 따를 것
- Stop Conditions에 해당하면: 사람에게 확인 후 진행
- .knowledge/ 디렉토리의 파일을 직접 읽지 말 것
```

---

## 6. 도메인 도출 (LLM 기반)

정제 파이프라인이 `entry_domains` 테이블의 항목을 생성하는 흐름. 도메인 배정은 **LLM이 판단**한다. `domain_paths`의 경로 패턴은 참조 자료이지 기계적 매칭 규칙이 아니다 — 경로 매칭만으로는 횡단 관심사, 비즈니스 문맥, 적절한 추상화 수준을 판단할 수 없다.

```
PR 변경 맥락 (커밋 메시지, 리뷰 논의, Linear 이슈)
+ 기존 도메인 레지스트리 (domain_registry)
+ 경로 패턴 참조 (domain_paths)
    ↓
  추출 LLM이 종합적으로 판단하여 도메인 배정
    예: 결제 서비스 리팩토링 PR → domain: payment
    예: AR callback 장애 수정 PR → domain: payment, activerecord
    ↓
  배정된 도메인으로 entry_domains 테이블에 INSERT
    ↓
  매칭 도메인이 없는 경우:
    → LLM이 {name, description, suggested_patterns}를 제안
    → knowledge-gate domain-add + domain-paths-set으로 반영
    → 후속 도메인 검토/재편(정제 배치 8단계, §3.1 B)에서 불필요하면 병합/폐기
```

**도메인 정의 가이드라인 (추출 프롬프트에 포함):**

- **입도(granularity):** 팀이 독립적으로 의사결정하는 단위. "payment"은 적절하지만 "payment-refund"와 "payment-charge"로의 과분할은 지양
- **횡단 관심사:** 특정 디렉토리에 국한되지 않는 규칙(보안 정책, 테스트 관행, 에러 처리 등)은 기술적 횡단 도메인으로 분류
- **명명 규칙:** 소문자 kebab-case, 비즈니스 도메인과 기술 도메인을 구분 (예: `payment` vs `activerecord`)

매 정제 배치 후 도메인 셋업에서 `domain-report` 결과를 참조하여 도메인 레지스트리와 `domain_paths` 패턴을 함께 검토·갱신한다.

---

## 7. 유틸리티 커맨드

운영·유지보수를 위한 보조 커맨드.

### migrate

PRAGMA user_version 기반 스키마 마이그레이션을 수행한다.

```bash
knowledge-gate migrate
```

**동작:**

1. `PRAGMA user_version` 조회 → 현재 스키마 버전 확인
2. 마이그레이션 스크립트 디렉토리(`schema/migrations/`)에서 현재 버전 이후 스크립트를 순차 실행
3. 각 스크립트 실행 후 `PRAGMA user_version = N` 갱신
4. 전체 과정을 단일 트랜잭션으로 래핑 (실패 시 롤백)

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

`curation_queue`의 pending 항목을 인터랙티브로 순차 검토·해소한다.

```bash
knowledge-gate curate
```

**동작:**

1. `curation_queue`에서 `status = 'pending'` 항목을 조회
2. 각 항목에 대해 충돌 내용(기존 entry vs 신규 entry)을 표시
3. 사용자가 액션을 선택:
   - `keep-both` — 양쪽 모두 active 유지, 큐 항목을 resolved 처리
   - `keep-existing` — 신규 entry를 superseded 처리
   - `keep-new` — 기존 entry를 superseded 처리
   - `archive-both` — 양쪽 모두 superseded 처리
   - `skip` — 이 항목 건너뛰기 (pending 유지)
   - `quit` — 즉시 종료

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

## 커맨드 요약

| 커맨드 | 용도 | 사용 주체 |
|---|---|---|
| `query-paths <filepath>` | 파일 경로로 관련 규칙 조회 | 에이전트 |
| `query-domain <domain>` | 도메인으로 규칙 조회 | 에이전트 |
| `search <keyword>` | FTS5 키워드 검색 | 에이전트 |
| `get <id>` | 항목 전체 상세 조회 | 에이전트 |
| `list` | 활성 항목 요약 목록 (탐색/키워드 발견용) | 에이전트 / 인간 |
| `add` | 항목 추가. 필수 필드 검증(스키마 CHECK + R3/R5) + vault.db INSERT | 정제 파이프라인 / 인간 |
| `domain-info <domain>` | 도메인 상세 (설명, 패턴, 항목 수) | 에이전트 / 인간 |
| `domain-list [--status]` | 도메인 레지스트리 조회 | 에이전트 / 인간 |
| `domain-resolve-path <filepath>` | 파일→도메인 역조회 | 에이전트 / 인간 |
| `domain-add` | 도메인 등록 | 정제 파이프라인 |
| `domain-merge` | 도메인 병합 (도메인 이관 포함) | 정제 파이프라인 |
| `domain-split` | 도메인 분할 (도메인 재배정 포함) | 정제 파이프라인 |
| `domain-deprecate` | 도메인 폐기 | 정제 파이프라인 |
| `domain-paths-set` | 도메인 경로 패턴 일괄 설정 | 정제 파이프라인 |
| `domain-paths-add` | 경로 패턴 추가 | 정제 파이프라인 |
| `domain-paths-remove` | 경로 패턴 제거 | 정제 파이프라인 |
| `domain-report` | 도메인 상태 진단 + 조정 후보 표면화 | 정제 파이프라인 / 인간 |
| `_pipeline-insert` | 파이프라인 전용 일괄 INSERT (JSON stdin) | 정제 파이프라인 (내부) |
| `migrate` | PRAGMA user_version 기반 스키마 마이그레이션 | 관리자 |
| `curate` | curation_queue 인터랙티브 해소 | 인간 |
