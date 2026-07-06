# PR Triage 사전 필터링 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mark-evidence 스킬 내부에 2단계 triage(결정론적 규칙 + LLM)를 추가해 `knowledge:pending` 큐 진입 PR을 줄이고, batch-refine report에 deferred queue와 운영 metric을 노출하며, recall regression 검증용 backtest 도구를 빌드한다.

**Architecture:** Layer 1(결정론적, manifest 빌드 전) + Layer 2(LLM, manifest 빌드 후)가 mark-evidence skill 내부에 순차 배치됨. 새 라벨 `knowledge:skipped` / `knowledge:deferred` 와 PR 코멘트 내 `<!-- KD_TRIAGE_DECISION_* -->` 블록이 상태 머신의 single source of truth. batch-refine의 per-PR 추출 루프는 변경하지 않는다. 다만 Step 1 discovery는 `knowledge:pending` 또는 `knowledge:deferred` 로 확장하고, `pending == 0 && deferred > 0` 이면 추출 없이 report-only batch 를 생성한다. `triage-backtest.sh` 는 `knowledge-gate` CLI의 새 `recent-accepted-prs` 서브커맨드로 과거 accepted entry의 source PR을 가져와 Layer 1(bash 재구현) + Layer 2(`claude` CLI) 시뮬레이션 후 positive-recall regression rate 산출.

**Tech Stack:** Bash + `gh` CLI + `git` + GitHub MCP + Linear MCP + `claude` CLI + sqlite3(knowledge-gate 내부). 스킬 본체는 markdown 지시문.

**Spec:** [`docs/specs/2026-05-27-pr-triage-pre-filter-design.md`](../specs/2026-05-27-pr-triage-pre-filter-design.md)

---

## File Structure

| 파일 | 변경 종류 | 책임 |
|---|---|---|
| `plugins/knowledge-distillery/skills/mark-evidence/SKILL.md` | Modify | Step 1 idempotency 재작성, Layer 1 신설 (Step 2 직전), Layer 2 신설 (Step 9 직전) |
| `plugins/knowledge-distillery/skills/batch-refine/SKILL.md` | Modify | Step 4 (Maintain Report PR)에 deferred 수집/metric 집계 추가, Report PR Format에 두 섹션 추가 |
| `plugins/knowledge-distillery/scripts/knowledge-gate` | Modify | `recent-accepted-prs` 서브커맨드 추가 |
| `plugins/knowledge-distillery/scripts/triage-backtest.sh` | **Create** | Layer 1 bash 재구현 + Layer 2 `claude` CLI invoke + markdown/JSON 리포트 |
| `tests/knowledge-gate.sh` | Modify | 새 서브커맨드 테스트 추가 |
| `tests/triage-backtest.sh` | **Create** | backtest 스크립트 단위 테스트 |
| `tests/all.sh` | Modify | 새 테스트 등록 |

테스트 가능성에 대한 솔직한 주석:
- **bash 코드(knowledge-gate, triage-backtest.sh)**: 기존 `tests/*.sh` 패턴(직접 호출 + `assert_*` helper)으로 TDD 적용 가능.
- **SKILL.md 변경**: 자동화된 행동 검증 인프라가 없다. 검증은 (1) 수동 invoke (fixture PR에 대해 `claude` CLI로 skill 호출), (2) backtest 스크립트가 vault에 들어간 과거 PR로 회귀 측정. 각 SKILL.md 변경 task는 "검증 단계"에 수동 invoke 절차를 명시한다.

---

## 사전 준비 (모든 task 공통)

### Branch
이 plan 전체를 단일 브랜치 `refine-pipeline-scalability` 에서 진행. 이미 spec/decision 커밋 2개가 있다 (`92e1ea1`, `2d1548a`, `2e4a855`).

### 테스트 실행
```bash
bash tests/all.sh
```
이 단일 명령으로 전체 테스트 스위트를 돌린다. task별로 부분 테스트만 돌릴 수도 있다.

### 검증용 fixture PR 후보 (수동 검증 시)
이 레포의 과거 PR 중 다음 카테고리에 해당하는 번호를 미리 메모해두면 좋다:
- **lockfile-only**: 의존성 봇 PR (예: dependabot이 `pnpm-lock.yaml` 만 수정한 PR)
- **docs + decision 신호**: ADR/CONTEXT.md 변경 PR
- **typical feature**: 일반 코드 변경 PR
- **bot + non-dependency 변경** (R1이 skip하지 않아야 함): codemod/release bot PR
fixture PR이 부족하면 task 진행 중 직접 만든 테스트 PR로 대체.

---

## Task 1: `knowledge-gate recent-accepted-prs` 서브커맨드 (TDD)

**Files:**
- Create test: `tests/knowledge-gate.sh` (기존 파일에 새 케이스 추가)
- Modify: `plugins/knowledge-distillery/scripts/knowledge-gate`

**책임:** vault DB에서 최근 N개 accepted entry의 source PR 번호를 추출하는 CLI surface. backtest 스크립트가 이를 통해 vault에 직접 접근하지 않고 PR 후보를 얻는다.

### 출력 계약

```
$ knowledge-gate recent-accepted-prs --limit 5
42
47
50
51
53
```

- stdout: PR 번호 한 줄에 하나, 중복 제거, 최근 entry 순 (created_at desc) → 그 entry들의 evidence ref(`#NN` 패턴)에서 추출한 PR 번호
- `--limit N`: 기본 50, 1 이상 정수
- entry가 없거나 적으면 가능한 만큼만 출력 (에러 아님)
- 잘못된 `--limit` 값은 stderr 에러 + 비-0 종료

### Step 1: vault 스키마에서 evidence 저장 형식 확인

- [ ] `plugins/knowledge-distillery/schema/vault.sql` 를 읽고 `entries` 테이블의 evidence 컬럼 형식 확인 (JSON 배열에 `{type, ref}` 객체들이 들어있을 것)

```bash
grep -A 20 "CREATE TABLE entries" plugins/knowledge-distillery/schema/vault.sql
```

확인 결과를 다음 step의 SQL에 반영. 만약 evidence 구조가 예상과 다르면 (예: 별도 테이블로 분리) SQL 쿼리를 그에 맞게 조정.

### Step 2: 실패하는 테스트 추가

`tests/knowledge-gate.sh` 끝 부분(EXIT trap 직전)에 케이스 추가:

```bash
# --- recent-accepted-prs 케이스 ---
RECENT_VAULT="$TMP_DIR/recent.db"
KNOWLEDGE_VAULT_PATH="$RECENT_VAULT" "$GATE" init-db "$RECENT_VAULT" >/dev/null

# knowledge-gate add 는 domain 존재를 검증함 → 먼저 test domain 등록
KNOWLEDGE_VAULT_PATH="$RECENT_VAULT" "$GATE" domain-add test "Test domain for backtest CLI" >/dev/null

# 3개 accepted entry 삽입 (evidence ref는 #10, #20, #20, #30)
KNOWLEDGE_VAULT_PATH="$RECENT_VAULT" "$GATE" add \
  --type fact --title "t1" --claim "c1" --body "b1" \
  --domain test --considerations "x" --evidence "pr:#10" >/dev/null
KNOWLEDGE_VAULT_PATH="$RECENT_VAULT" "$GATE" add \
  --type fact --title "t2" --claim "c2" --body "b2" \
  --domain test --considerations "x" --evidence "pr:#20" >/dev/null
KNOWLEDGE_VAULT_PATH="$RECENT_VAULT" "$GATE" add \
  --type fact --title "t3" --claim "c3" --body "b3" \
  --domain test --considerations "x" --evidence "pr:#20,pr:#30" >/dev/null

OUT="$(KNOWLEDGE_VAULT_PATH="$RECENT_VAULT" "$GATE" recent-accepted-prs --limit 50)"
LINE_COUNT="$(echo "$OUT" | wc -l | tr -d ' ')"
assert_eq "3" "$LINE_COUNT" "recent-accepted-prs: should dedupe and return 3 unique PRs"
assert_contains "$OUT" "10" "recent-accepted-prs: contains PR 10"
assert_contains "$OUT" "20" "recent-accepted-prs: contains PR 20"
assert_contains "$OUT" "30" "recent-accepted-prs: contains PR 30"

OUT_LIMITED="$(KNOWLEDGE_VAULT_PATH="$RECENT_VAULT" "$GATE" recent-accepted-prs --limit 1)"
LIM_COUNT="$(echo "$OUT_LIMITED" | wc -l | tr -d ' ')"
# limit 1이면 최신 entry 1개의 evidence만 반환 (위에서 마지막에 추가한 t3 → #20, #30)
assert_eq "2" "$LIM_COUNT" "recent-accepted-prs: --limit 1 returns refs from most recent entry only"
```

- [ ] **Step 2: 테스트 추가 후 실패 확인**

```bash
bash tests/knowledge-gate.sh
```

기대: `FAIL: ...` (서브커맨드 미구현). 다른 기존 케이스는 통과해야 함.

### Step 3: 서브커맨드 구현

`plugins/knowledge-distillery/scripts/knowledge-gate` 의 `case "$CMD" in` 블록에 케이스 추가. 실제 스키마 (`schema/vault.sql` 확인 결과): `entries` 와 `evidence` 는 **별도 테이블**이며 `entries.evidence` 컬럼은 존재하지 않는다. `evidence(entry_id, type, ref)` 를 JOIN 해서 `type='pr'` 행만 추출.

evidence.ref 는 add 시 입력한 그대로 저장된다 (예: `#10`). PR 번호만 출력하기 위해 leading `#` 을 strip.

```bash
recent-accepted-prs)
  LIMIT=50
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit)
        LIMIT="${2:-}"
        if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
          echo "Invalid --limit: $LIMIT" >&2
          exit 2
        fi
        shift 2
        ;;
      *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  # 최근 LIMIT 개의 active entry → evidence(type='pr') JOIN → ref 중복 제거 → '#' strip
  sqlite3 "$VAULT" <<SQL | sed 's/^#//' | awk 'NF && !seen[$0]++'
SELECT DISTINCT e.ref
FROM evidence e
WHERE e.type = 'pr'
  AND e.entry_id IN (
    SELECT id FROM entries
    WHERE status = 'active'
    ORDER BY created_at DESC
    LIMIT ${LIMIT}
  );
SQL
  ;;
```

> 참고: 위 SQL 은 `--limit N` 을 entries 기준으로 적용하고, 그 entries 의 모든 pr evidence ref 를 dedupe 해서 출력. 테스트 케이스 "--limit 1 → 2 lines" 는 최신 entry 1개(t3) 의 evidence 2개(`#20`, `#30`)가 반환되는 것을 검증.

- [ ] **Step 3: 구현 추가**

코드 추가 후 헬프 텍스트도 갱신:

```bash
# Diagnostics & Maintenance 위쪽 Agent Runtime Commands 섹션에:
  recent-accepted-prs [--limit N]  Recent active entries' source PR numbers
```

### Step 4: 테스트 재실행 → 통과 확인

- [ ] 테스트 실행

```bash
bash tests/knowledge-gate.sh
```

기대: 모든 케이스 통과. 실패하면 SQL 또는 awk 파이프라인을 디버깅.

### Step 5: 커밋

- [ ] memento-commit 스킬로 커밋

```bash
git add plugins/knowledge-distillery/scripts/knowledge-gate tests/knowledge-gate.sh
# (memento-commit 스킬 호출 — `/knowledge-distillery:memento-commit` 또는 동등 절차)
```

커밋 메시지 예: `feat(knowledge-gate): recent-accepted-prs 서브커맨드 추가`

---

## Task 2: mark-evidence Step 1 (idempotency) 5-case 상태 머신 재작성

**Files:**
- Modify: `plugins/knowledge-distillery/skills/mark-evidence/SKILL.md:45-66`

**책임:** mark-evidence 재실행 시 라벨 + decision 블록 조합별 동작을 명시. 새 라벨 도입으로 인한 oscillation 방지.

### Step 1: 현재 Step 1 블록을 읽고 위치 확인

- [ ] `plugins/knowledge-distillery/skills/mark-evidence/SKILL.md` 의 `### Step 1: Idempotency Check` 섹션 (line 45 부터) 을 읽는다.

### Step 2: Step 1 본문을 다음 5-case 룰로 교체

- [ ] **Edit 도구로 Step 1 본문 교체.** 헤더 (`### Step 1: Idempotency Check`)는 유지하고 그 아래 본문을 다음으로 교체:

```markdown
### Step 1: Idempotency Check

PR의 라벨과 코멘트(manifest comment, triage decision 블록)를 함께 읽고 다음 5가지 케이스 중 하나로 분기한다.

```
Use GitHub MCP to fetch PR #{pr_number}: labels, issue comments (bodies only).
```

확인할 마커:
- 라벨: `knowledge:pending`, `knowledge:skipped`, `knowledge:deferred`
- 코멘트 블록: `<!-- EVIDENCE_BUNDLE_MANIFEST_START -->`, `<!-- KD_TRIAGE_DECISION_START -->`

분기 규칙 (순서대로 평가, 첫 매칭에서 종료):

| 케이스 | 조건 | 동작 |
|---|---|---|
| C1a | `knowledge:pending` 라벨 **AND** Manifest 블록 존재 | 그대로 종료. Manifest 중복 게시 금지, 라벨도 유지 (`mark-evidence` 의 "exactly one Manifest" 제약 보호). |
| C1b | `knowledge:pending` 라벨 존재 **AND** Manifest 블록 없음 | 사람이 `skipped`/`deferred` → `pending` 으로 promote 했거나 이전 실행의 부분 실패 케이스. Triage(Layer 1, Layer 2)를 건너뛰고 Step 2~8 로 Manifest를 구성한 뒤 Step 9 의 Manifest comment 게시까지 실행한다. Step 9 의 pending 라벨 추가는 이미 pending 이므로 no-op. |
| C2 | `knowledge:skipped` 라벨 AND `KD_TRIAGE_DECISION` 블록 존재 | 그대로 종료. 어떤 라벨/코멘트도 추가하지 않는다. |
| C3 | `knowledge:deferred` 라벨 AND `KD_TRIAGE_DECISION` 블록 존재 | 그대로 종료. 어떤 라벨/코멘트도 추가하지 않는다. |
| C4 | Manifest 블록만 존재 (triage decision 블록 없음, 위 라벨 모두 없음) | 기존 idempotency 동작. `knowledge:pending` 라벨이 없으면 다시 붙이고 종료. |
| C5 | 위 조건 모두 해당 없음 | 신규 PR로 간주. Step 1.5 (Layer 1) 부터 정상 흐름. |

**중요 (manual promote 경로)**: 사람이 `skipped`/`deferred` → `pending` 으로 라벨을 바꾼 경우 보통 KD_TRIAGE_DECISION 블록만 있고 Manifest 블록은 없다. → **C1b** 로 분기해 Triage 재실행 없이 Manifest 만 생성한다. KD_TRIAGE_DECISION 블록은 그대로 보존 (이력 기록).
```

### Step 3: 검증 — fixture PR 시나리오 mental walkthrough

- [ ] 6가지 케이스 각각에 대해 다음을 직접 따라 읽으며 분기 결과가 의도와 일치하는지 확인:
  - 신규 PR (라벨 없음, 코멘트 없음) → C5 → 정상 흐름 (Layer 1 부터)
  - 기존 pending PR (이미 manifest + pending 라벨) → **C1a** → 그대로 종료, Manifest 중복 게시 안 됨
  - 라벨만 있고 Manifest 없는 pending PR (부분 실패 또는 promote 직후) → **C1b** → Triage skip, Manifest 만 생성
  - 이미 skipped된 PR → C2 → no-op
  - 이미 deferred된 PR → C3 → no-op
  - 옛날 pending PR이지만 라벨이 누락된 경우 (Manifest 만 있음) → C4 → 라벨 재부여
  - 사람이 deferred → pending으로 변경 (KD_TRIAGE_DECISION 블록 있음, Manifest 없음) → **C1b** → Manifest 생성

문제 발견 시 표 수정 후 재확인.

### Step 4: 커밋

- [ ] 커밋 메시지: `docs(mark-evidence): Step 1 idempotency를 5-case 상태 머신으로 재작성`

---

## Task 3: Layer 1 (결정론적 규칙) 을 mark-evidence SKILL.md 에 추가

**Files:**
- Modify: `plugins/knowledge-distillery/skills/mark-evidence/SKILL.md` — Step 2 직전에 새 "Step 1.5: Layer 1 Triage" 추가

**책임:** R1-R4 결정론적 규칙으로 명백한 lockfile/generated/dependency-bot/auto-revert PR을 조기 skip. Manifest 빌드와 LLM 호출 모두 절약.

### Step 1: 새 섹션 본문 작성

- [ ] **Edit 도구로 `### Step 2: Gather PR Metadata` 직전에 다음 블록 삽입:**

```markdown
### Step 1.5: Layer 1 Deterministic Triage

Manifest 빌드 전에 4가지 결정론적 규칙을 평가한다. 하나라도 매칭하면 즉시 skip 처리하고 Manifest 빌드/Layer 2/이후 단계를 모두 건너뛴다.

**필요한 입력 — Step 2의 전체 페치 전에 최소한만 먼저 페치:**

```
Use GitHub MCP to fetch PR #{pr_number}: title, body, author (login + is_bot), changed files (paths only).
```

**규칙 (하나라도 매칭하면 skip):**

| # | 조건 | skip reason |
|---|---|---|
| R1 | `author.is_bot == true` **AND** PR 제목이 dependency/update 자동화 패턴(아래)에 매칭 **AND** 변경 파일 *전부*가 dependency metadata, lockfile, generated 패턴 중 하나 | `bot-dependency-update` |
| R2 | 변경된 파일 *전부*가 lockfile 패턴에 매칭 | `lockfile-only` |
| R3 | 변경된 파일 *전부*가 generated 패턴에 매칭 | `generated-only` |
| R4 | PR 제목이 `Revert "` 로 시작 **AND** body가 비어있거나 GitHub의 auto-revert 패턴(`This reverts commit <sha>.`만 있음) | `auto-revert` |

**파일 패턴 (glob, fnmatch 의미):**

Lockfile:
```
*-lock.json, *.lock, Gemfile.lock, Cargo.lock, package-lock.json,
yarn.lock, pnpm-lock.yaml, poetry.lock, uv.lock, composer.lock,
mix.lock, go.sum
```

Generated:
```
**/generated/**, **/__generated__/**, dist/**, build/**,
**/*.snap, **/__snapshots__/**
```

Dependency metadata (R1 전용):
```
package.json, pyproject.toml, requirements*.txt, Gemfile, go.mod,
Cargo.toml, composer.json, mix.exs
```

Dependency/update 자동화 제목 패턴 (R1 전용, 대소문자 무시 부분 일치):
```
dependabot, renovate, bump, update dependency, update dependencies,
upgrade dependency, upgrade dependencies
```

**Skip 시 동작:**

1. `knowledge:skipped` 라벨이 repo에 없으면 생성:
   ```
   Use GitHub MCP to ensure the label `knowledge:skipped` exists on the repository (description: "PR triaged as low-value, excluded from knowledge pipeline", color: "BBBBBB"). If it already exists, continue without error.
   ```
2. 짧은 triage decision 코멘트 게시:
   ```markdown
   <!-- KD_TRIAGE_DECISION_START -->
   ```json
   {"layer": "L1", "rule": "<rule reason from table>", "decision": "skip"}
   ```
   Skipped by triage: <human-readable reason>
   <!-- KD_TRIAGE_DECISION_END -->
   ```
3. `knowledge:skipped` 라벨 추가.
4. 종료 (Step 2 이후 실행하지 않음).

**규칙 평가 순서:** R1 → R2 → R3 → R4. 매칭되면 즉시 break.

**규칙 매칭이 없으면:** Step 2 (Gather PR Metadata)로 진행. Step 1.5에서 페치한 데이터는 Step 2에서 재사용 가능 (중복 페치 회피).
```

### Step 2: 라벨 ensure 위치 일관성 확인

- [ ] 기존 Step 9의 label ensure 패턴 (line 244-247)을 검토. Layer 1 skip 경로의 label ensure 패턴이 동일한 스타일인지 확인. 일관성 OK이면 진행.

### Step 3: 수동 검증 절차 (자동화 불가)

- [ ] 다음 절차를 plan 실행자가 직접 수행하도록 문서화:

수동 검증 시나리오:

1. **lockfile-only PR**: `pnpm-lock.yaml` 만 변경된 머지된 PR을 하나 골라 다음 명령 실행:
   ```bash
   # mark-evidence를 수동 invoke (label/comment 부수효과를 감수 — 테스트 PR을 쓸 것)
   claude --plugin-dir ./plugins/knowledge-distillery \
     "Use skill /knowledge-distillery:mark-evidence for PR #<number>."
   ```
   기대: PR에 `knowledge:skipped` 라벨이 붙고 `KD_TRIAGE_DECISION` 코멘트가 게시됨. Manifest 코멘트는 없음.

2. **generated-only PR**: `dist/**` 만 변경된 PR. 같은 절차로 R3 매칭 확인.

3. **dependabot dependency PR**: `package.json` + `package-lock.json` 변경 + 제목 "Bump foo from 1 to 2". R1 매칭 확인.

4. **non-matching PR**: 일반 코드 변경 PR. 기존 흐름대로 Manifest 빌드 + `knowledge:pending` 라벨 부여 확인.

5. **codemod bot PR** (R1이 *skip하지 않아야* 함): 봇 작성자이지만 코드 파일 변경. R1의 AND 조건이 충족되지 않아 정상 흐름 진행 확인.

각 시나리오 통과 확인 후 다음 task로.

### Step 4: 커밋

- [ ] 커밋 메시지: `feat(mark-evidence): Layer 1 결정론적 triage 추가 (R1-R4)`

---

## Task 4: Layer 2 (LLM triage) 을 mark-evidence SKILL.md 에 추가

**Files:**
- Modify: `plugins/knowledge-distillery/skills/mark-evidence/SKILL.md` — Step 8 (Compose Manifest) 와 Step 9 (Post Comment and Add Label) 사이에 새 "Step 8.5: Layer 2 LLM Triage" 삽입

**책임:** Manifest 빌드 후 추가 메타데이터로 LLM 분류기를 호출. docs-only + 결정 신호 없음, test-only + manifest 신호 없음 등 nuance 회색 영역 처리. extract / skip / defer 결정.

### Step 1: 새 섹션 본문 작성

- [ ] **Edit 도구로 `### Step 9: Post Comment and Add Label` 직전에 다음 블록 삽입:**

```markdown
### Step 8.5: Layer 2 Triage (Internal Judgment)

**중요 — 실행 모델**: 이 Step 은 **별도 LLM 호출이 아니다**. mark-evidence 스킬을 수행하는 Claude 자신이 아래 판정 기준을 적용해 `decision payload` 를 **직접 구성**한다. payload 는 PR 코멘트에 기록할 데이터 형식이지 별도 모델의 응답이 아니다. 따라서 "JSON 파싱 실패" 같은 실패 경로는 존재하지 않는다 — 판정 신뢰가 낮으면 반드시 `extract` 를 선택한다.

**입력 (의도적으로 제한 — full diff 제외):**

다음 항목만 판정 컨텍스트로 사용:
- PR title (Step 2)
- PR body (Step 2)
- PR labels (Step 1.5에서 페치된 라벨 또는 별도 재페치)
- PR author login (Step 1.5)
- 변경 파일 경로 목록 + 각 +/- 라인 수
- Manifest 요약: `linear[]` 개수, `slack[]` 개수, `memento[]` 존재 여부, `greptile[]` 코멘트 합계, `notion[]` 개수
- 메인 커밋 메시지 (최대 5개, 각 메시지 최대 200자에서 잘림)

**제외 (반드시):** full diff, full memento 본문, full Linear 본문.

**판정 기준 (Claude 가 직접 적용):**

- **보수 편향**: 확실히 낮은 가치일 때만 `skip`. 애매하면 `extract` 또는 `defer`. 판정 신뢰가 낮으면 무조건 `extract`.
- `skip` 대상 패턴:
  - docs-only 변경 (`.md`, `.txt`, `.rst`, `**/docs/**`) + 결정/정책 신호 *없음*
    - 결정 키워드 (대소문자 무시 부분 일치): `decide`, `decision`, `convention`, `policy`, `ADR`, `deprecate`, `adopt`, `must`, `must not`, `결정`, `정책`, `규칙`, `채택`, `금지`, `폐기`, `합의`
    - 결정 경로: `docs/adr/`, `docs/decisions/`, `CONTEXT.md`, `RFC*`
    - 위 신호가 *하나라도* 있으면 skip 금지.
  - test-only 변경 (`*_test.*`, `*.test.*`, `**/__tests__/**`) + manifest 신호 부재 (linear/slack/memento/notion/greptile 카운트 모두 0)
  - i18n/번역 (`**/locales/**`, `*.po`, `*.pot`)
- `defer` 대상: 회색 영역 (예: 큰 PR + manifest 신호 빈약, 혼합 변경) — 사람 큐레이션이 필요한 경우.
- `extract`: 위 외 모든 경우 (기본값) — **모든 신뢰 낮은 판정도 여기로**.

**Decision Payload 형식 (PR 코멘트 기록용):**

```json
{"layer":"L2","decision":"<skip|extract|defer>","reason":"<한 문장>","signals":["<bullet>"]}
```

**결정별 동작 — 모든 경우에 Manifest 코멘트에 KD_TRIAGE_DECISION 블록 *추가*:**

| decision | 블록 추가 | 라벨 |
|---|---|---|
| `extract` | Manifest 코멘트에 payload 블록 추가 | `knowledge:pending` (Step 9 의 기존 흐름) |
| `skip` | Manifest 코멘트에 payload 블록 추가 | `knowledge:skipped` (ensure → add), Step 9 건너뜀 |
| `defer` | Manifest 코멘트에 payload 블록 추가 | `knowledge:deferred` (ensure → add), Step 9 건너뜀 |

**중요 — extract 도 블록 기록 의무**: 운영 metric 의 "Layer 2 extract 수" 집계의 단일 진실원천은 KD_TRIAGE_DECISION 블록이다. extract 시에도 블록을 빼면 metric 이 비어버린다.

**블록 형식 (실제 PR 코멘트에 추가될 raw text):**

```markdown
<!-- KD_TRIAGE_DECISION_START -->
```json
{"layer": "L2", "decision": "extract", "reason": "code changes present with manifest signals", "signals": ["src/ files changed", "linear ID found"]}
```
<!-- KD_TRIAGE_DECISION_END -->
```

(skip / defer 케이스도 동일 형식, `decision` 값만 다름.)

**Defer 라벨 ensure (defer 결정 시):**

```
Use GitHub MCP to ensure the label `knowledge:deferred` exists on the repository (description: "PR triage requires human curation", color: "FF8800"). If it already exists, continue without error.
```

**처리 순서 (모든 decision 공통):**

1. Manifest 코멘트에 KD_TRIAGE_DECISION 블록을 *append* (Step 8 의 Manifest 게시와 같은 PR 코멘트 본문에 추가).
2. decision 별 라벨 ensure + add.
3. extract 면 Step 9 의 기존 흐름 (라벨 추가 부분만 — 이미 위에서 했으니 idempotent), skip/defer 면 Step 9 건너뜀.
```

### Step 2: Step 9 (Post Comment and Add Label) 의 idempotency 노트 강화

- [ ] Step 9의 첫 문장 직후에 다음 주석 추가:

```markdown
> **주의:** 이 Step은 Layer 2가 `extract` 판정을 내렸을 때만 실행된다. `skip`/`defer` 판정 시 Step 8.5에서 라벨/코멘트가 이미 부여되었고 이 Step은 건너뛴다.
```

### Step 3: 수동 검증 시나리오

- [ ] 다음 시나리오 각각을 수동 invoke로 확인:

1. **docs-only + 결정 신호 없음** (예: `README.md` 오타 수정 PR) → `skip` 기대.
2. **docs + ADR** (예: `docs/adr/0042-xyz.md` 추가 PR) → `extract` 기대 (skip 금지).
3. **test-only + 신호 없음** (예: 새 테스트 케이스 추가 PR, Linear ID 없음) → `skip` 기대.
4. **typical feature PR** (코드 변경 + Linear ID 있음) → `extract` 기대.
5. **혼합 변경 + manifest 빈약** (예: 큰 PR, 여러 파일 type, 외부 컨텍스트 없음) → `defer` 가능.

각 시나리오의 실제 결과가 기대와 다르면 프롬프트의 "판정 가이드" 부분을 수정해 재시도.

### Step 4: 커밋

- [ ] 커밋 메시지: `feat(mark-evidence): Layer 2 LLM triage 추가 (skip/extract/defer)`

---

## Task 5: batch-refine Report 에 Deferred Queue 섹션 추가

**Files:**
- Modify: `plugins/knowledge-distillery/skills/batch-refine/SKILL.md` — Step 1 (Discover), Step 4 (Maintain Report PR), "Report PR Format" 섹션

**책임:** Step 1 디스커버리에 deferred PR 포함, 3-branch 분기 처리 (pending>0 / pending==0 AND deferred>0 / 둘 다 0). report 에 Deferred Queue 섹션 추가. spec `## deferred PR 라이프사이클` 절 반영.

### Step 1: batch-refine Step 1 (Discover) 를 3-branch 로 재작성

- [ ] `### Step 1: Discover Pending PRs` 본문 (현재 `pending` 만 조회 + "no results → exit 0") 을 다음으로 교체:

```markdown
### Step 1: Discover Pending or Deferred PRs

```
Use GitHub MCP to list merged PRs with the `knowledge:pending` label (fields: number, title, mergedAt).
Then use GitHub MCP to list merged PRs with the `knowledge:deferred` label (fields: number, title, author.login).
```

pending PR 을 `mergedAt` ascending 으로 정렬. 다음 3-branch 로 분기:

| 분기 | 조건 | 동작 |
|---|---|---|
| B1 | pending > 0 | Step 2 부터 기존 흐름 (추출 루프). Step 4 의 report 갱신에서 Deferred Queue 도 함께 노출. |
| B2 | pending == 0 AND deferred > 0 | **report-only batch**. Step 2 의 branch 는 생성하되 Step 3 추출 루프는 *skip*. Step 4 의 report 갱신 시 빈 changeset (`entries: []`) 생성, Deferred Queue 섹션만 채움. PR 본문에 "이번 batch 는 deferred queue 검토 전용" 명시. |
| B3 | pending == 0 AND deferred == 0 | 기존처럼 exit 0 (branch / commit / PR 생성 없음). |

**PoC 정책 — open report PR 갱신은 범위 외**: B2 에서도 매 batch 마다 새 branch (`knowledge/batch-YYYY-MM-DD`) + 새 report PR 을 생성. 이전 batch 의 report PR 은 그대로 둔다. 운영 결과 deferred-only PR 이 자주 생성되면 후속 PR 에서 정책 조정.
```

### Step 2: Report PR Format 에 Deferred Queue 섹션 추가

- [ ] `## Report PR Format` 섹션 내부, `### Insufficient Evidence (Remains Pending)` 직전에 다음 추가:

```markdown
### Deferred Queue (Human Curation Required)

triage 가 `defer` 판정을 내린 PR. 사람이 라벨을 변경해야 다음 batch 에 반영됩니다.

| PR | 작성자 | 제목 | Defer 사유 |
|----|--------|------|------------|
| #{n} | @{author} | {title} | {reason from KD_TRIAGE_DECISION block} |

**사람 검토 가이드:**
- 지식 가치가 있다고 판단 → 라벨을 `knowledge:deferred` → `knowledge:pending` 으로 변경 (mark-evidence 의 idempotency C1b 로 진입).
- 영구 제외 → 라벨을 `knowledge:deferred` → `knowledge:skipped` 로 변경 (사유는 PR 코멘트에 남길 것 권장).
```

(B2 분기의 report-only PR 본문에는 위 섹션만 채워지고 Summary / Accepted Entries / Rejected Candidates 등은 비어 있음을 명시.)

### Step 3: Step 4 (Maintain Report PR) 에 deferred 수집 절차 추가

- [ ] `### Step 4: Maintain Report PR` 의 끝 부분 (reviewers 처리 직후, "MUST NOT auto-merge" 직전) 에 다음 단락 추가:

```markdown
**Deferred Queue 수집 (Report 갱신 시마다, B1 / B2 분기 공통):**

```
Use GitHub MCP to list merged PRs with the `knowledge:deferred` label (fields: number, title, author.login). For each PR, fetch the issue comments and locate the latest `<!-- KD_TRIAGE_DECISION_START -->` block to extract the `reason` field from the JSON payload.
```

- 수집된 PR 을 Report PR Format 의 "Deferred Queue" 섹션 표에 채워 넣는다. 없으면 표는 빈 상태 (헤더만) 로 둔다.
- 이 수집은 추출 파이프라인을 실행하지 않는다 — 단순 리스팅만 수행.
- B2 분기 (deferred-only batch) 에서는 이 수집이 report 본문의 *유일한 동적 컨텐츠*다.
```

### Step 4: 검증 절차

- [ ] 다음 시나리오 mental walkthrough:

1. pending > 0, deferred 0 → B1, 기존 흐름, Deferred Queue 빈 표.
2. pending > 0, deferred 2 (PR #100, #101) → B1, 추출 + Deferred Queue 표에 2 행.
3. pending 0, deferred 3 → **B2**, branch 생성 / 빈 changeset / report-only PR, Deferred Queue 표에 3 행.
4. pending 0, deferred 0 → B3, exit 0, 부수효과 없음.
5. PR 이 `deferred → pending` 으로 라벨 변경 → 다음 batch B1 으로 진입, 해당 PR 추출 루프에 포함, Deferred Queue 에서 빠짐.

### Step 5: 커밋

- [ ] 커밋 메시지: `feat(batch-refine): Step 1 3-branch + report Deferred Queue 섹션`

---

## Task 6: batch-refine Report 에 운영 Metric 섹션 추가

**Files:**
- Modify: `plugins/knowledge-distillery/skills/batch-refine/SKILL.md` — Step 4 (Maintain Report PR) 와 "Report PR Format" 섹션

**책임:** PoC 운영 중 데이터 기반 결정을 위한 metric 노출. 후속 작업(GitHub Actions pre-step 승격, 외부화, 프롬프트 튜닝)의 trigger 데이터.

### Step 1: Report PR Format 에 새 섹션 템플릿 추가

- [ ] `## Report PR Format` 의 `### Summary` 직후에 다음 추가:

```markdown
### 운영 Metric (Triage)

이번 batch 기준 누적값입니다. 추세 추적용.

| Metric | 값 |
|--------|----|
| Layer 1 skip 수 | {N} ({reason breakdown: bot-dependency-update=N, lockfile-only=N, generated-only=N, auto-revert=N}) |
| Layer 2 skip 수 | {N} |
| Layer 2 defer 수 | {N} |
| Layer 2 extract 수 | {N} |
| `knowledge:pending` 큐 길이 (batch 시작 시) | {N} |
| `knowledge:skipped` 누적 PR 수 (전체) | {N} |
| 최근 positive-recall regression rate (수동 backtest) | {X.X%} ({date}) |
```

### Step 2: Step 4 에 metric 수집 절차 추가

- [ ] Task 5에서 추가한 "Deferred Queue 수집" 블록 직후에 다음 추가:

```markdown
**운영 Metric 수집 (Report 갱신 시마다):**

모든 Layer 2 결정 (skip / extract / defer) 은 PR 코멘트의 `KD_TRIAGE_DECISION` 블록에 기록되어 있다 (spec 합의). 따라서 라벨별로 PR 을 조회한 뒤 각 PR 의 최신 KD_TRIAGE_DECISION 블록을 파싱해 layer / decision / reason 으로 group by.

1. **Layer 1 skip** — `knowledge:skipped` 라벨 PR 중 블록의 `layer == "L1"` 인 것:
   ```
   Use GitHub MCP to list merged PRs with the `knowledge:skipped` label (fields: number, body of latest KD_TRIAGE_DECISION comment).
   ```
   - 파싱 후 `layer == "L1"` 인 것만 `rule` 별 카운트 → 표의 "Layer 1 skip 수 (reason breakdown)" 채움.

2. **Layer 2 skip** — 같은 조회 결과에서 `layer == "L2"` AND `decision == "skip"` 카운트.

3. **Layer 2 defer** — `knowledge:deferred` 라벨 PR (Task 5 의 Deferred Queue 수집에서 이미 조회됨) 의 수 = `decision == "defer"` 카운트와 동일.

4. **Layer 2 extract** — `knowledge:pending` 라벨 또는 이미 처리된 (`knowledge:collected`) PR 중 블록이 있고 `decision == "extract"` 인 것:
   ```
   Use GitHub MCP to list merged PRs with the `knowledge:pending` OR `knowledge:collected` label. For each, fetch latest KD_TRIAGE_DECISION block (may be absent for PRs marked before triage was introduced — skip those).
   ```

5. **`knowledge:pending` 큐 길이 (batch 시작 시)** — Step 1 의 B1 / B2 / B3 분기 평가 시 이미 카운트했으므로 그 값을 그대로 사용.

6. **`knowledge:skipped` 누적 PR 수 (전체)** — Step 1 의 블록과 같은 GitHub MCP list 호출의 total 사용.

7. **최근 positive-recall regression rate (수동 backtest)** — `.knowledge/reports/triage-backtest-YYYY-MM-DD.md` 중 가장 최근 파일의 결과를 인용. 파일이 없으면 "N/A".

**비용 주의**: 매 batch 마다 전체 라벨 카운트를 다시 조회하는 것이 부담되면, PoC 단계에서는 *이번 batch 에 포함된 PR* 만 집계해도 좋다. 정확성보다 추세 추적이 목적.
```

### Step 3: 검증

- [ ] Mental walkthrough — metric이 항상 모순 없이 채워지는지 (예: skip 수 합 = `knowledge:skipped` 카운트, defer 수 = `knowledge:deferred` 카운트).

### Step 4: 커밋

- [ ] 커밋 메시지: `feat(batch-refine): report에 운영 metric 섹션 추가`

---

## Task 7: `triage-backtest.sh` 스켈레톤 + Layer 1 재구현 (TDD)

**Files:**
- Create: `plugins/knowledge-distillery/scripts/triage-backtest.sh`
- Create: `tests/triage-backtest.sh`
- Modify: `tests/all.sh` — 새 테스트 등록

**책임:** 과거 accepted entry의 source PR을 가져와 Layer 1 (bash 재구현) 으로 시뮬레이션. Layer 2는 다음 task에서 추가.

### Step 1: 실패하는 테스트 작성

- [ ] `tests/triage-backtest.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/plugins/knowledge-distillery/scripts/triage-backtest.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
assert_contains() {
  local hay="$1" needle="$2" msg="$3"
  [[ "$hay" == *"$needle"* ]] || fail "$msg: missing '$needle'"
}

# --- L1 rule unit-testing via stdin contract ---
# 스크립트가 다음 stdin 포맷을 받아 L1 판정을 stdout에 출력하는 sub-mode를 갖도록 설계:
#   echo '{"author":{"login":"dependabot[bot]","is_bot":true},"title":"Bump foo 1->2","files":["package.json","package-lock.json"],"body":""}' \
#     | triage-backtest.sh --layer1-only
# 출력: 한 줄 JSON {"decision":"skip","rule":"bot-dependency-update"} 또는 {"decision":"pass"}

# Case 1: bot dependency PR → R1 skip
OUT="$(echo '{"author":{"login":"dependabot[bot]","is_bot":true},"title":"Bump foo from 1 to 2","files":["package.json","package-lock.json"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R1: bot+dep PR should skip"
assert_contains "$OUT" '"rule":"bot-dependency-update"' "R1: reason should be bot-dependency-update"

# Case 2: lockfile-only PR → R2 skip
OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"chore: update deps","files":["pnpm-lock.yaml"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R2: lockfile-only should skip"
assert_contains "$OUT" '"rule":"lockfile-only"' "R2: reason should be lockfile-only"

# Case 3: generated-only PR → R3 skip
OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"chore: regen","files":["dist/bundle.js","dist/bundle.js.map"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R3: generated-only should skip"

# Case 4: auto-revert PR → R4 skip
OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"Revert \"feat: x\"","files":["src/x.ts"],"body":"This reverts commit abc123."}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"skip"' "R4: auto-revert should skip"
assert_contains "$OUT" '"rule":"auto-revert"' "R4: reason should be auto-revert"

# Case 5: typical PR → pass
OUT="$(echo '{"author":{"login":"alice","is_bot":false},"title":"feat: add API","files":["src/api.ts","src/api.test.ts"],"body":"Adds new endpoint."}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"pass"' "typical PR should pass"

# Case 6: codemod bot (R1이 skip하지 않아야 함) — files가 dependency가 아님
OUT="$(echo '{"author":{"login":"codemod-bot[bot]","is_bot":true},"title":"chore: migrate to new API","files":["src/legacy.ts","src/legacy.test.ts"],"body":""}' | bash "$SCRIPT" --layer1-only)"
assert_contains "$OUT" '"decision":"pass"' "codemod bot with code changes should pass (R1 narrow)"

echo "OK: triage-backtest L1 tests passed"
```

- [ ] 실행하여 실패 확인:

```bash
bash tests/triage-backtest.sh
```

기대: `FAIL: ...` (스크립트 미존재 또는 sub-mode 미구현).

### Step 2: `triage-backtest.sh` 스켈레톤 + Layer 1 구현

- [ ] `plugins/knowledge-distillery/scripts/triage-backtest.sh` 생성:

```bash
#!/usr/bin/env bash
# triage-backtest.sh — Triage Layer 1/2 backtest against past accepted PRs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="${SCRIPT_DIR}/knowledge-gate"
# ROOT = repo top (scripts → plugin → kd → repo)
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Argument parsing ---
MODE="full"  # full | layer1-only | layer2-only
LIMIT=50
while [ $# -gt 0 ]; do
  case "$1" in
    --layer1-only) MODE="layer1-only"; shift ;;
    --layer2-only) MODE="layer2-only"; shift ;;
    --limit) LIMIT="${2:-50}"; shift 2 ;;
    -h|--help) echo "Usage: $0 [--layer1-only|--layer2-only] [--limit N]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- Lazy dependency check (mode-conditional) ---
require_tool() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Required tool not found: $tool" >&2; exit 3; }
  done
}
case "$MODE" in
  layer1-only) require_tool jq ;;
  layer2-only|full) require_tool jq gh claude sqlite3 ;;
esac

# --- Layer 1 rule patterns ---
LOCKFILE_REGEX='^(.*-lock\.json|.*\.lock|Gemfile\.lock|Cargo\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|uv\.lock|composer\.lock|mix\.lock|go\.sum)$'
GENERATED_REGEX='(^|/)(generated|__generated__|dist|build|__snapshots__)(/|$)|\.snap$'
DEPS_META_REGEX='^(package\.json|pyproject\.toml|requirements.*\.txt|Gemfile|go\.mod|Cargo\.toml|composer\.json|mix\.exs)$'
DEPS_AUTO_TITLE_REGEX='dependabot|renovate|^bump|update dependenc|upgrade dependenc'

# layer1_eval — stdin: PR JSON; stdout: {"decision":"skip|pass",["rule":"..."]}
layer1_eval() {
  local pr_json="$1"
  local author_is_bot author_login title body
  local -a files
  author_is_bot=$(echo "$pr_json" | jq -r '.author.is_bot')
  author_login=$(echo "$pr_json" | jq -r '.author.login')
  title=$(echo "$pr_json" | jq -r '.title')
  body=$(echo "$pr_json" | jq -r '.body // ""')
  mapfile -t files < <(echo "$pr_json" | jq -r '.files[]')

  if [ "${#files[@]}" -eq 0 ]; then
    echo '{"decision":"pass"}'
    return
  fi

  # R4: auto-revert
  if [[ "$title" == Revert\ \"* ]] && { [ -z "$body" ] || [[ "$body" =~ ^This\ reverts\ commit\ [a-f0-9]+\.$ ]]; }; then
    echo '{"decision":"skip","rule":"auto-revert"}'
    return
  fi

  # R1: bot + dep automation title + all files in dep-related set
  if [ "$author_is_bot" = "true" ] && [[ "$(echo "$title" | tr '[:upper:]' '[:lower:]')" =~ $DEPS_AUTO_TITLE_REGEX ]]; then
    local all_dep=true
    for f in "${files[@]}"; do
      if ! [[ "$f" =~ $DEPS_META_REGEX || "$f" =~ $LOCKFILE_REGEX || "$f" =~ $GENERATED_REGEX ]]; then
        all_dep=false; break
      fi
    done
    if [ "$all_dep" = "true" ]; then
      echo '{"decision":"skip","rule":"bot-dependency-update"}'
      return
    fi
  fi

  # R2: lockfile-only
  local all_lock=true
  for f in "${files[@]}"; do
    [[ "$f" =~ $LOCKFILE_REGEX ]] || { all_lock=false; break; }
  done
  if [ "$all_lock" = "true" ]; then
    echo '{"decision":"skip","rule":"lockfile-only"}'
    return
  fi

  # R3: generated-only
  local all_gen=true
  for f in "${files[@]}"; do
    [[ "$f" =~ $GENERATED_REGEX ]] || { all_gen=false; break; }
  done
  if [ "$all_gen" = "true" ]; then
    echo '{"decision":"skip","rule":"generated-only"}'
    return
  fi

  echo '{"decision":"pass"}'
}

# --- Mode dispatch ---
if [ "$MODE" = "layer1-only" ]; then
  # stdin은 단일 PR JSON
  PR_JSON=$(cat)
  layer1_eval "$PR_JSON"
  exit 0
fi

# full / layer2-only 모드는 Task 8에서 구현
echo "Mode '$MODE' not yet implemented (see Task 8)" >&2
exit 1
```

- [ ] 실행 권한 부여:

```bash
chmod +x plugins/knowledge-distillery/scripts/triage-backtest.sh
```

### Step 3: 테스트 재실행 → 통과 확인

- [ ] 테스트 실행:

```bash
bash tests/triage-backtest.sh
```

기대: `OK: triage-backtest L1 tests passed`. 실패하면 regex/조건을 디버깅.

### Step 4: `tests/all.sh` 에 등록

- [ ] `tests/all.sh` 에 한 줄 추가:

```bash
bash "${ROOT}/tests/triage-backtest.sh"
```

마지막 줄로 추가. 전체 테스트 실행으로 통합 확인:

```bash
bash tests/all.sh
```

### Step 5: 커밋

- [ ] 커밋 메시지: `feat(triage-backtest): Layer 1 결정론적 규칙 bash 재구현`

---

## Task 8: `triage-backtest.sh` Layer 2 (LLM) 통합 + Full backtest 모드

**Files:**
- Modify: `plugins/knowledge-distillery/scripts/triage-backtest.sh`
- Modify: `tests/triage-backtest.sh` — full 모드 smoke test 추가 (선택)

**책임:** Layer 2는 `claude` CLI 로 동일한 triage 프롬프트를 invoke. full 모드는 `recent-accepted-prs` → 각 PR metadata 페치 → L1 → (pass면) L2 → 결과 집계.

### Step 1: Layer 2 호출 헬퍼 작성

- [ ] `triage-backtest.sh` 의 `layer1_eval` 함수 아래에 다음 추가:

```bash
# layer2_eval — args: PR JSON with manifest summary; stdout: {"decision":"skip|extract|defer",...}
layer2_eval() {
  local pr_json="$1"
  local prompt
  prompt=$(cat <<EOF
당신은 PR triage 분류기입니다. 다음 PR이 knowledge-distillery 파이프라인에서 처리할 가치가 있는지 판단합니다.

[PR 데이터]
$(echo "$pr_json" | jq .)

[판정 가이드]
- 보수 편향: 확실히 낮은 가치일 때만 "skip". 애매하면 "extract" 또는 "defer".
- "skip" 대상: docs-only + 결정 신호 없음, test-only + manifest 신호 부재, i18n only.
  - 결정 키워드: decide, decision, convention, policy, ADR, deprecate, adopt, must, must not, 결정, 정책, 규칙, 채택, 금지, 폐기, 합의
  - 결정 경로: docs/adr/, docs/decisions/, CONTEXT.md, RFC*
- "defer": 큰 PR + manifest 신호 빈약, 혼합 변경 등 신뢰 못 할 때.
- "extract": 기본값.

[출력] JSON 한 줄. 주석 금지:
{"decision":"skip|extract|defer","reason":"<한 문장>","signals":["<bullet>"]}
EOF
)
  # claude CLI invocation — stdout-only, no plugin context needed (분류기는 vault 접근 X)
  local response
  response=$(echo "$prompt" | claude --print 2>/dev/null || true)
  # JSON 한 줄만 추출 (최후 라인)
  local json
  json=$(echo "$response" | grep -oE '\{[^}]*"decision"[^}]*\}' | tail -1)
  if [ -z "$json" ] || ! echo "$json" | jq . >/dev/null 2>&1; then
    # fallback to extract
    echo '{"decision":"extract","reason":"parse-fallback","signals":[]}'
    return
  fi
  echo "$json"
}
```

### Step 2: Full 모드 구현

- [ ] `Mode dispatch` 의 `exit 1` 부분을 다음으로 교체:

```bash
# --- Full backtest mode ---
DATE=$(date +%Y-%m-%d)
REPORT_MD="${ROOT}/.knowledge/reports/triage-backtest-${DATE}.md"
REPORT_JSON="${ROOT}/.knowledge/reports/triage-backtest-${DATE}.json"
mkdir -p "$(dirname "$REPORT_MD")"

PR_NUMBERS=$("$GATE" recent-accepted-prs --limit "$LIMIT")
TOTAL=0
SKIPPED=0
declare -A REASONS_L1
declare -A REASONS_L2

echo "[" > "$REPORT_JSON.tmp"
FIRST=true

for pr_num in $PR_NUMBERS; do
  TOTAL=$((TOTAL + 1))
  # PR metadata fetch via gh — labels, files (path+additions+deletions), comments(for manifest)
  pr_meta=$(gh pr view "$pr_num" --json author,title,body,files,labels,comments 2>/dev/null || echo "")
  if [ -z "$pr_meta" ]; then
    continue
  fi

  # Manifest summary 추출 — production L2 입력과 동일하게 맞추기 위해
  # 기존 PR 코멘트의 EVIDENCE_BUNDLE_MANIFEST 블록에서 identifier 카운트만 뽑음
  manifest_json=$(echo "$pr_meta" | jq -r '.comments[].body' \
    | awk 'BEGIN{p=0;j=0} /<!-- EVIDENCE_BUNDLE_MANIFEST_START -->/{p=1;next} /<!-- EVIDENCE_BUNDLE_MANIFEST_END -->/{p=0;next} p && /^```json$/{j=1;next} p && j && /^```$/{j=0;next} p && j' \
    | jq -s '.[0] // {}' 2>/dev/null || echo '{}')
  manifest_summary=$(echo "$manifest_json" | jq '{
    linear: ((.identifiers.linear // []) | length),
    slack: ((.identifiers.slack // []) | length),
    memento: (((.identifiers.memento // []) | length) > 0),
    greptile_comments: ([(.identifiers.greptile // [])[] | (.comment_count // 0)] | add // 0),
    notion: ((.identifiers.notion // []) | length)
  }')

  # Layer 1 입력 — Layer 1 은 author/title/files/body 만 사용 (labels/sizes 무시)
  l1_input=$(echo "$pr_meta" | jq '{author: .author, title: .title, body: .body, files: [.files[].path]}')
  l1=$(layer1_eval "$l1_input")
  l1_dec=$(echo "$l1" | jq -r '.decision')
  if [ "$l1_dec" = "skip" ]; then
    SKIPPED=$((SKIPPED + 1))
    rule=$(echo "$l1" | jq -r '.rule')
    REASONS_L1["$rule"]=$((${REASONS_L1["$rule"]:-0} + 1))
    entry=$(jq -c -n --arg pr "$pr_num" --argjson l1 "$l1" '{pr:$pr, layer:"L1", result:$l1}')
  else
    # Layer 2 입력 — production 과 동일하게 labels + additions/deletions + manifest_summary 포함
    l2_input=$(echo "$pr_meta" | jq --argjson ms "$manifest_summary" '{
      author: .author,
      title: .title,
      body: .body,
      labels: [.labels[].name],
      files: [.files[] | {path: .path, additions: .additions, deletions: .deletions}],
      manifest_summary: $ms
    }')
    l2=$(layer2_eval "$l2_input")
    l2_dec=$(echo "$l2" | jq -r '.decision')
    if [ "$l2_dec" = "skip" ]; then
      SKIPPED=$((SKIPPED + 1))
      REASONS_L2["skip"]=$((${REASONS_L2["skip"]:-0} + 1))
    elif [ "$l2_dec" = "defer" ]; then
      REASONS_L2["defer"]=$((${REASONS_L2["defer"]:-0} + 1))
    else
      REASONS_L2["extract"]=$((${REASONS_L2["extract"]:-0} + 1))
    fi
    entry=$(jq -c -n --arg pr "$pr_num" --argjson l2 "$l2" '{pr:$pr, layer:"L2", result:$l2}')
  fi

  if [ "$FIRST" = "true" ]; then FIRST=false; else echo "," >> "$REPORT_JSON.tmp"; fi
  echo "$entry" >> "$REPORT_JSON.tmp"
done

echo "]" >> "$REPORT_JSON.tmp"
mv "$REPORT_JSON.tmp" "$REPORT_JSON"

# Markdown 보고서
{
  echo "# Triage Backtest — ${DATE}"
  echo
  echo "## 요약"
  echo "- 총 평가 PR: ${TOTAL}"
  if [ "$TOTAL" -gt 0 ]; then
    PCT=$(awk -v s="$SKIPPED" -v t="$TOTAL" 'BEGIN { printf "%.2f", (s/t)*100 }')
  else
    PCT="N/A"
  fi
  echo "- skip 판정 (positive-recall regression): ${SKIPPED} / ${TOTAL} = ${PCT}%"
  echo "- threshold: ≤ 5%"
  echo
  echo "## Layer 1 skip breakdown"
  for k in "${!REASONS_L1[@]}"; do echo "- ${k}: ${REASONS_L1[$k]}"; done
  echo
  echo "## Layer 2 decision breakdown"
  for k in "${!REASONS_L2[@]}"; do echo "- ${k}: ${REASONS_L2[$k]}"; done
  echo
  echo "_상세는 ${REPORT_JSON} 참고._"
} > "$REPORT_MD"

echo "Backtest complete. Report: $REPORT_MD"
```

### Step 3: 테스트

- [ ] `tests/triage-backtest.sh` 의 L1 테스트는 그대로 통과해야 함:

```bash
bash tests/triage-backtest.sh
```

- [ ] Full 모드 smoke test (선택, GitHub auth 필요):

```bash
# 실제 vault + gh auth 가 있는 환경에서:
bash plugins/knowledge-distillery/scripts/triage-backtest.sh --limit 5
# 출력: "Backtest complete. Report: .../triage-backtest-YYYY-MM-DD.md"
cat .knowledge/reports/triage-backtest-*.md
```

### Step 4: 커밋

- [ ] 커밋 메시지: `feat(triage-backtest): Layer 2 LLM 통합 + full backtest 모드`

---

## Task 9: 실제 데이터로 backtest 실행하고 ≤5% 임계 확인

**Files:** (변경 없음 — 검증 단계)

**책임:** 진짜 vault 데이터에 대해 backtest를 돌려 positive-recall regression rate 가 임계 이하인지 확인. 임계 초과 시 규칙/프롬프트 수정 → Task 3/4/7/8로 돌아가 반복.

### Step 1: 사전 점검

- [ ] vault 에 충분한 accepted entry 가 있는지 확인:

```bash
plugins/knowledge-distillery/scripts/knowledge-gate list | wc -l
```

10개 미만이면 backtest 신호가 약하므로 Task 9를 보류 (또는 limit을 그에 맞춤). 적어도 20개 이상 권장.

### Step 2: backtest 실행

- [ ] 다음 실행 (현재 vault 기준 가능한 만큼):

```bash
bash plugins/knowledge-distillery/scripts/triage-backtest.sh --limit 50
```

### Step 3: 결과 평가

- [ ] 생성된 `.knowledge/reports/triage-backtest-YYYY-MM-DD.md` 확인:
  - "skip 판정 ... ≤ 5%" 인가?
  - Layer 1 skip breakdown 에서 의외의 reason 이 다수 (예: bot-dependency-update 가 너무 많이 잡힘)?
  - Layer 2 skip 사유에 false positive 가 있는가?

### Step 4: 임계 초과 시 대응 분기

- [ ] **≤ 5%** → 다음 단계 (Task 10).
- [ ] **> 5%** → 어느 layer 가 원인인지 분리:
  - Layer 1 원인 → Task 3로 돌아가 규칙 narrow (예: R3 generated 패턴이 너무 광범위)
  - Layer 2 원인 → Task 4로 돌아가 프롬프트의 "판정 가이드" 강화 (skip 조건을 더 좁힘)
  - 수정 후 Task 7/8 의 backtest 재실행
  - reasoning trace 를 `.knowledge/reports/triage-backtest-YYYY-MM-DD-iterN.md` 로 비교

### Step 5: 결과 기록

- [ ] 최종 backtest 보고서를 git 에 커밋 (`.knowledge/reports/` 는 이미 tracked):

```bash
git add .knowledge/reports/triage-backtest-*.md .knowledge/reports/triage-backtest-*.json
# memento-commit
```

커밋 메시지 예: `chore: triage backtest baseline (positive-recall regression X.XX%)`

---

## Task 10: 최종 통합 검증 + PR 작성

**Files:** (변경 없음 — 종합 검증)

### Step 1: 전체 테스트 스위트 통과 확인

- [ ] 

```bash
bash tests/all.sh
```

모든 case 통과.

### Step 2: 라벨 사전 생성 (선택, 첫 mark-evidence 실행 전에 race 회피)

- [ ] 

```bash
gh label create knowledge:skipped --description "PR triaged as low-value, excluded from knowledge pipeline" --color BBBBBB || true
gh label create knowledge:deferred --description "PR triage requires human curation" --color FF8800 || true
```

### Step 3: PR 생성

- [ ] 

```bash
git push -u origin refine-pipeline-scalability
gh pr create --base main --title "feat: PR triage 사전 필터링 (L1 결정론적 + L2 LLM)" --body "$(cat <<'EOF'
## Summary
- spec: `docs/specs/2026-05-27-pr-triage-pre-filter-design.md`
- plan: `docs/plans/2026-05-27-pr-triage-pre-filter-plan.md`

## Changes
- mark-evidence: Layer 1 결정론적 규칙 (R1-R4) + Layer 2 LLM triage (skip/extract/defer) + 5-case idempotency
- batch-refine: report에 Deferred Queue + 운영 Metric 섹션 추가
- knowledge-gate: `recent-accepted-prs` 서브커맨드 추가
- triage-backtest.sh: positive-recall regression 측정 도구

## Validation
- `tests/all.sh` 통과
- backtest 결과: positive-recall regression X.XX% (≤ 5%)

## Out of scope (별도 PR)
- 일별 mini-batch 전환
- PR 병렬 처리
- 레포별 triage 규칙 외부화
EOF
)"
```

### Step 4: 후속 작업 노트

- [ ] PR 본문 또는 follow-up issue 에 다음 명시:
  - 운영 1주일 후 Layer 1 skip 비율 / mark-evidence 실행 비용 점검 → GitHub Actions pre-step 승격 여부 판단
  - 운영 1주일 후 정확도 데이터 누적 → 레포별 규칙 외부화 필요성 판단
  - cheap-tier 모델 분리는 Claude Code Action 환경의 모델 전환 mechanism 확정 후 별도 PR

---

## 자체 검토 — 스펙 커버리지 매핑

| 스펙 섹션 | 매핑 task |
|---|---|
| 아키텍처 (Layer 1 in skill, future promotion path) | Task 3 |
| Layer 1 결정론적 규칙 (R1-R4) | Task 3, Task 7 (bash 재구현) |
| Layer 2 Triage (internal judgment, decision payload) | Task 4 (skill), Task 8 (backtest simulation) |
| 라벨 + 모든 결정 기록 (skip / extract / defer 블록) | Task 3 (L1 코멘트), Task 4 (L2 블록 — extract 포함), Task 10 (라벨 생성) |
| idempotency C1a/C1b/C2/C3/C4/C5 | Task 2 |
| deferred PR 라이프사이클 (3-branch B1/B2/B3) | Task 5 |
| 운영 metric (모든 L2 결정 집계) | Task 6 |
| Validation: positive-recall 샘플링 (시뮬레이션 명시) | Task 1, 7, 8, 9 |
| 에러 처리 (low-confidence → extract) | Task 4 (skill), Task 8 (backtest claude CLI 호출 실패) |
| 변경 영향 요약 (batch-refine Step 1 포함) | 모든 task의 Files 섹션과 일치 |

**Placeholder scan 결과:** 없음. 모든 step 에 구체 코드/명령/검증 절차 포함.

**Type consistency:** decision 값 `"skip"|"extract"|"defer"`, layer 값 `"L1"|"L2"`, rule 값 `bot-dependency-update|lockfile-only|generated-only|auto-revert` — 전체 plan 에서 일관. 라벨 매핑 `skip → knowledge:skipped`, `defer → knowledge:deferred`, `extract → knowledge:pending` 일관.

**리뷰 피드백 반영 결과 (2026-05-27 외부 리뷰):**

| 리뷰 지적 | 반영 위치 |
|---|---|
| #1 Manifest 중복 게시 | Task 2 — C1 → C1a (종료) + C1b (Triage skip 후 Manifest 만 생성) 분리 |
| #2 Deferred-only report 누락 | Task 5 — Step 1 을 pending OR deferred 로 확장, 3-branch (B1/B2/B3) |
| #3 L2 self-prompting 모순 | Task 4 — "출력 스키마/JSON 파싱" → "internal judgment / decision payload 구성" |
| #4 L2 extract metric 집계 불가 | Task 4 — extract 시에도 KD_TRIAGE_DECISION 블록 기록 의무화 / Task 6 — pending+collected 라벨도 조회 |
| #5 Task 1 테스트 domain 미생성 | Task 1 Step 2 — `domain-add test "Test domain"` 선행 |
| #6 recent-accepted-prs SQL 스키마 불일치 | Task 1 Step 3 — JOIN 기반 SQL (entries + evidence 별도 테이블) |
| #7 backtest ROOT 미정의 + dep check 위치 | Task 7 Step 2 — ROOT = `git rev-parse --show-toplevel`, dep check 를 mode-conditional 로 |
| #8 backtest L2 입력이 production 과 다름 | Task 8 Step 2 — labels + additions/deletions + manifest_summary 포함 |
