# PR Triage 사전 필터링 설계

- 작성일: 2026-05-27
- 작성자: ether (브레인스토밍 합의 기록)
- 상태: 설계 합의 완료, 구현 계획 대기

## 배경

`knowledge-distillery`를 한 달에 100개 이상 PR이 생성되는 레포지토리에 적용한 결과, 주 1회 `batch-refine`을 돌려도 누적된 `knowledge:pending` 큐의 10%도 처리하지 못하는 처리량 문제가 발견되었다.

병목은 모든 머지된 PR이 동일한 무게로 `collect-evidence → extract-candidates → quality-gate` 풀 파이프라인(PR당 LLM 호출 2-3회)을 거친다는 점이다. 실제로는 의존성 봇 PR, 잠금 파일만 변경된 PR, 자동 생성 파일만 변경된 PR 등 지식이 거의 안 나오는 PR이 큐의 상당 부분을 차지한다.

## 목표

- `knowledge:pending` 큐에 들어가는 PR 자체를 줄여 batch-refine 처리량을 회복한다.
- 낮은 가치 PR은 명확한 사유와 함께 기록을 남기고 영구 제외한다 (recall regression 검증을 위한 데이터).
- 회색 영역 PR은 사람 큐레이션 큐로 분리한다.
- 기존 batch-refine의 serial 처리 / atomic commit / graceful handoff 보장은 건드리지 않는다.

## 비-목표

- PR 병렬 처리 (현 serial 설계 의도와 충돌)
- 일별 미니 배치로의 전환 (별도 작업)
- 레포별 triage 규칙 외부화 / 사용자 설정 UI (YAGNI)
- 이미 `knowledge:pending` 라벨이 붙은 과거 PR의 backfill

## 아키텍처

triage 로직은 **mark-evidence 스킬 내부**에 위치한다. 별도 단계나 별도 워크플로우를 만들지 않는 이유는 skip 결정의 부수효과(라벨 적용, PR 코멘트 게시)가 mark-evidence가 이미 책임지는 부수효과와 정확히 같은 종류이기 때문이다. 분리하면 책임만 흩어진다.

이 선택은 `mark-evidence` workflow의 Claude Code Action 실행 비용을 제거하지 않는다. PoC의 1차 목표는 Claude 실행 자체가 아니라 `knowledge:pending` 큐 진입과 Stage B 풀 파이프라인 진입을 줄이는 것이다. 운영 후 Layer 1 skip 비율이 높고 `mark-evidence` 실행 비용도 의미 있는 병목으로 확인되면, 동일한 Layer 1 규칙을 GitHub Actions pre-step으로 승격해 Claude 실행 전에 skip한다.

PR이 머지되면 다음 흐름을 따른다.

```
PR merged
  └─ mark-evidence workflow trigger
       └─ Layer 1: deterministic rules (manifest 빌드 전)
            ├─ skip 판정 → knowledge:skipped 라벨 + 짧은 skip 코멘트 → 끝
            └─ 통과 → 계속
       └─ 기존 manifest 빌드 (Linear ID, Slack URL, memento 존재 여부 등)
       └─ Layer 2: LLM triage (manifest + 메타데이터 입력, full diff 아님)
            ├─ skip → knowledge:skipped + 사유, manifest 코멘트에 triage 블록 추가
            ├─ defer → knowledge:deferred + 사유 (다음 batch report에서 사람 검토)
            └─ extract → knowledge:pending (기존 동작 그대로)
```

핵심 설계 결정:

- **Layer 1은 manifest 빌드 전**에 실행해 명백한 lockfile/generated PR에 대한 manifest 수집, Linear 조회, memento 확인, Stage B 진입을 절약한다. 단, Claude Code Action 실행 자체는 절약하지 않는다.
- **Layer 2는 manifest 빌드 후**에 실행해 manifest의 신호(memento 유무, Linear 연결 여부 등)를 입력에 활용한다.
- **batch-refine의 처리 루프는 변경하지 않는다.** 여전히 `knowledge:pending` 라벨로만 추출 대상을 디스커버리하며 serial 처리, atomic commit/label, graceful handoff를 유지한다. 다만 report 생성 시 `knowledge:deferred` PR을 별도 섹션에 나열한다.

## Layer 1: 결정론적 규칙

PoC 단계에서는 외부화 없이 스킬 내부에 hard-coded한다. 4개 규칙 중 *하나라도* 매칭하면 즉시 skip한다 (신뢰도 점수 없음 — boolean으로 충분, 회색 영역은 Layer 2가 담당).

| # | 규칙 | skip reason |
|---|---|---|
| R1 | PR `author.is_bot == true` AND 제목이 dependency/update automation 패턴 AND 변경 파일 전부가 dependency metadata, lockfile, generated 파일 중 하나 | `bot-dependency-update` |
| R2 | 변경된 파일 *전부*가 잠금 파일 패턴에 매칭 | `lockfile-only` |
| R3 | 변경된 파일 *전부*가 생성 파일 패턴에 매칭 | `generated-only` |
| R4 | 제목이 `Revert "..."` 시작 + body 비어있거나 auto-generated 패턴 | `auto-revert` |

### 파일 패턴 기본값

잠금 파일:
```
*-lock.json, *.lock, Gemfile.lock, Cargo.lock, package-lock.json,
yarn.lock, pnpm-lock.yaml, poetry.lock, uv.lock, composer.lock,
mix.lock, go.sum
```

생성 파일:
```
**/generated/**, **/__generated__/**, dist/**, build/**,
**/*.snap, **/__snapshots__/**
```

Dependency metadata (R1 전용):
```
package.json, pyproject.toml, requirements*.txt, Gemfile, go.mod,
Cargo.toml, composer.json, mix.exs
```

Dependency/update automation 제목 패턴 (R1 전용):
```
dependabot, renovate, bump, update dependency, update dependencies,
upgrade dependency, upgrade dependencies
```

### 의도적으로 제외한 규칙

- **docs-only** — Layer 2 nuance 영역. 설계 결정이 문서 PR에 담기는 경우가 많아 일괄 skip 불가.
- **`chore:`/`deps:` prefix** — false positive 위험. 실제 fix가 chore로 잘못 표기되는 경우 있음.
- **size 기반** — 1줄 fix가 결정을 담는 경우 있음. Layer 2가 판단.
- **빈 diff** — 이미 collect-evidence의 sufficiency 체크가 처리.
- **bot-author 단독 skip** — migration/release/codemod bot PR은 지식을 담을 수 있으므로 파일/제목 신호와 결합될 때만 skip한다.

### 구현 위치

mark-evidence 스킬 진입부에서 GitHub MCP로 `author`, `changedFiles`만 먼저 페치하여 4개 규칙을 평가한다. 매칭 시 skip 처리하고 manifest 빌드 단계를 건너뛴다. 매칭 안 되면 기존 manifest 빌드로 진행한다.

## Layer 2: LLM Triage

### 입력 (의도적으로 제한)

- PR 제목, body, 라벨 목록, author login
- 변경 파일 경로 목록 + 각 +/- 라인 수 (full diff 없음)
- Manifest 요약: Linear ID 개수, Slack URL 개수, memento note 존재 여부, Greptile 코멘트 개수, Notion URL 개수
- 메인 커밋 메시지 (최대 5개, 각 메시지 최대 200자에서 잘림)

### 제외

- full diff
- full memento 본문
- full Linear issue 본문

(이들은 모두 `extract-candidates` 단계의 영역이며, triage 단계에서 굳이 다 읽으면 비용 절감 효과가 사라진다.)

### Decision Payload 스키마

분류기는 다음 형식의 decision payload 를 구성한다. **별도 모델 응답이 아니다** — skill 을 수행하는 Claude 자신이 판정 기준에 따라 직접 결정 내리고, 이 payload 는 PR 코멘트의 `KD_TRIAGE_DECISION` 블록에 기록하는 데이터 형식이다.

**모든 Layer 2 결정 (skip / extract / defer) 에 대해 payload 를 작성해 PR 코멘트에 기록한다.** extract 도 예외 없다 — 운영 metric (Layer 2 extract 수) 집계의 single source of truth.

```json
{
  "layer": "L2",
  "decision": "skip" | "extract" | "defer",
  "reason": "<one line>",
  "signals": ["<bullet>", "..."]
}
```

판정 신뢰가 낮거나 조건이 애매하면 반드시 `extract` 를 선택한다. silently drop 회피 원칙.

### 판정 가이드 (분류기에 적용)

- **보수 편향**: *확실히 낮은 가치*일 때만 `skip`. 애매하면 `extract` 또는 `defer`.
- `skip` 대상 패턴:
  - docs-only 변경 + 결정/정책 신호 *없음*
    - 결정 신호 키워드: `decide`, `decision`, `convention`, `policy`, `ADR`, `deprecate`, `adopt`, `must`, `must not`, `결정`, `정책`, `규칙`, `채택`, `금지`, `폐기`, `합의`
    - 결정 신호 경로: `docs/adr/`, `docs/decisions/`, `CONTEXT.md`, `RFC*`
  - test-only 변경 (`*_test.*`, `*.test.*`, `**/__tests__/**`) + manifest 신호 부재 (Linear/Slack/memento/Notion/Greptile 카운트 모두 0)
  - i18n / 번역만 (`**/locales/**`, `*.po`, `*.pot`)
- `defer` 대상: 분류기가 신뢰 못 하는 경우 (사람 큐레이션 필요), 예: 큰 PR + manifest 신호 빈약
- `extract`: 위 외 모든 경우 (기본값)

### 모델 / 토큰

- Layer 2는 최소 입력으로 수행한다. 별도 cheap-tier 모델 호출은 구현 방법이 명확해진 뒤 후속 최적화로 둔다.
- 입력 <2k 토큰 목표 (full diff 제외 이유)
- 단일 응답 (스트리밍 X)

## 라벨 및 skip 사유 기록

### 새 라벨

| 라벨 | 색상 | 의미 |
|---|---|---|
| `knowledge:skipped` | 회색 (`BBBBBB`) | triage가 skip 판정 |
| `knowledge:deferred` | 주황 (`FF8800`) | triage가 사람 큐레이션 요청 |

### skip 사유 저장 형식

**Layer 1 skip 시** — manifest 빌드는 건너뛰고 짧은 코멘트만 게시:

```
<!-- KD_TRIAGE_DECISION_START -->
{"layer": "L1", "rule": "lockfile-only", "decision": "skip"}

Skipped by triage: lockfile-only changes
<!-- KD_TRIAGE_DECISION_END -->
```

**Layer 2 의 모든 결정 시 (skip / extract / defer)** — 기존 manifest 코멘트에 triage 결과 블록을 *추가*:

```
<!-- KD_TRIAGE_DECISION_START -->
{"layer": "L2", "decision": "skip", "reason": "docs-only with no decision signals", "signals": ["all 3 files are .md", "no decision keywords in title/body", "no ADR path"]}
<!-- KD_TRIAGE_DECISION_END -->
```

extract 케이스 예시 (라벨은 기존대로 `knowledge:pending` 부여):

```
<!-- KD_TRIAGE_DECISION_START -->
{"layer": "L2", "decision": "extract", "reason": "code changes present with manifest signals", "signals": ["src/ files changed", "linear ID found"]}
<!-- KD_TRIAGE_DECISION_END -->
```

라벨-결정 매핑:

| Layer 2 decision | 부여 라벨 |
|---|---|
| `skip` | `knowledge:skipped` |
| `defer` | `knowledge:deferred` |
| `extract` | `knowledge:pending` (기존 흐름) |

### idempotency

`mark-evidence` 재실행 시 Manifest 존재 여부만 보지 말고 PR 라벨과 `KD_TRIAGE_DECISION_START` 블록을 함께 해석한다.

1. `knowledge:pending` 라벨이 있으면 사람이 extract를 명시한 것으로 본다. triage를 다시 실행하지 않고 Manifest가 없으면 생성한다.
2. `knowledge:skipped` 라벨과 triage decision 블록이 있으면 그대로 종료한다. `knowledge:pending`을 다시 붙이지 않는다.
3. `knowledge:deferred` 라벨과 triage decision 블록이 있으면 그대로 종료한다. `knowledge:pending`을 다시 붙이지 않는다.
4. Manifest comment만 있고 triage decision 블록이 없으면 기존 idempotency 동작을 유지한다. `knowledge:pending`을 보장하고 종료한다.
5. `knowledge:skipped` 또는 `knowledge:deferred` 라벨이 있었지만 사람이 `knowledge:pending`으로 바꾼 경우, manual override로 간주한다. triage를 우회하고 Manifest를 생성 또는 보강한 뒤 다음 batch-refine 대상이 되게 한다.

### deferred PR 라이프사이클

batch-refine 의 Step 1 (Discover) 은 `knowledge:pending` 과 `knowledge:deferred` 라벨이 붙은 PR 을 함께 조회하도록 확장된다. 3-branch 흐름:

- **`pending > 0`** — 기존 추출 루프 실행. report 생성 단계에서 deferred 도 함께 "Deferred Queue" 섹션으로 노출.
- **`pending == 0 AND deferred > 0`** — 추출 루프 실행하지 않음. report-only batch branch + PR 을 생성. changeset 파일은 빈 `entries: []` 로 생성 (기존 파이프라인의 changeset 존재 가정 유지). report 본문은 Deferred Queue 섹션만 채움. **PoC 정책: 매 batch 마다 새 branch/PR 생성 — 기존 batch-refine 의 batch 주기/네이밍 규칙과 일관성 유지, open report PR 갱신은 PoC 범위 외.**
- **`pending == 0 AND deferred == 0`** — 기존처럼 exit 0 (branch/PR 생성 없음).

추출 파이프라인 (collect-evidence, extract-candidates, quality-gate) 은 어떤 분기에서도 deferred PR 을 절대 처리하지 않는다.

사람은 deferred PR 의 라벨을 직접 변경한다:

- `knowledge:deferred` → `knowledge:pending`: 다음 batch 의 추출 대상 (mark-evidence 의 idempotency C1 manual override 경로로 들어감)
- `knowledge:deferred` → `knowledge:skipped`: 영구 제외

## 에러 처리

| 실패 경로 | 동작 |
|---|---|
| Layer 1 입력 페치 실패 (author, files 조회) | Layer 1 건너뜀, manifest 빌드 + Layer 2 로 진행 |
| Layer 2 판정이 애매하거나 신뢰 낮음 (분류기 self-assessment) | **`extract` 선택** → `knowledge:pending` + decision payload (`reason: "low-confidence default"`) 기록 |
| Manifest comment 게시 실패 (Layer 2 payload 기록 단계) | 경고 로그 후 라벨만 적용 — payload 누락은 metric 일부 손실을 의미하나 mark-evidence 자체는 성공으로 간주 |
| 새 라벨 생성 실패 | 경고 로그 + 기존 동작 — mark-evidence 자체는 절대 실패하면 안 됨 |
| Backtest Layer 2 의 `claude --print` 호출 실패 / JSON 파싱 실패 | **backtest 행에 `extract` 기록** (production fallback 과 동일하게 처리). Skill 본체 실패와 무관. |

원칙: **silently drop 을 피한다.** 의심스러우면 처리하는 쪽으로 양보한다. production Layer 2 에는 별도 LLM 호출이 없으므로 "호출 timeout / JSON 파싱" 같은 실패 경로는 backtest 에만 존재한다.

## 운영 metric

PoC 운영 중 다음 값을 batch 또는 별도 보고서에 남긴다.

- Layer 1 skip count
- Layer 2 skip / defer / extract count
- skip reason breakdown
- `knowledge:pending` 큐 감소율
- sampled positive-recall regression 결과

이 지표로 Layer 1을 GitHub Actions pre-step으로 승격할지, repo별 설정을 외부화할지, Layer 2 프롬프트를 조정할지 판단한다.

## Validation: positive-recall 샘플링

### 시뮬레이션과 production 의 관계

backtest 는 production skill 과 **동일한 판정 프롬프트**를 사용하는 **시뮬레이션**이지만, **실행 경로는 동일하지 않다**:

- production Layer 2: mark-evidence skill 내부 판정 (skill 을 수행하는 Claude 자신이 결정 내리고 직접 행동)
- backtest Layer 2: `claude --print` 별도 CLI 호출 (독립된 Claude 인스턴스가 JSON 한 줄 반환)

이 경로 차이로 인해 backtest 결과는 production 동작의 *근사 proxy* 일 뿐 완전한 일치는 보장하지 않는다. positive-recall regression rate 는 *경향* 지표로 해석한다.

### 도구

`plugins/knowledge-distillery/scripts/triage-backtest.sh` — bash + `gh` CLI + `knowledge-gate`.

### 절차

1. `knowledge-gate`를 통해 최근 50개 accepted entry의 source PR 번호 조회
2. 각 PR에 대해 metadata를 페치 후 Layer 1 + Layer 2 시뮬레이션
   - Layer 1: bash 스크립트가 규칙을 *재구현* (skill과 동일한 패턴 사용, 단일 진실원천은 PoC에서는 허용)
   - Layer 2: `claude` CLI로 동일한 triage 프롬프트 invoke (mark-evidence 본체는 호출하지 않음 — 라벨/코멘트 부수효과 회피)
3. 결과 집계:
   - accepted entry source PR 중 skip 판정을 받은 비율 = **positive-recall regression rate**
   - PR별 skip 사유 breakdown
4. 결과 출력: markdown 보고서 + JSON

### Acceptance threshold

- ≤5% positive-recall regression rate → green (배포 가능)
- 5% 초과 → red (규칙 또는 프롬프트 수정 후 재실행)

### CI 포함 여부

CI에 포함하지 않는다. PoC 단계에서는 수동 실행으로 충분하며, vault 데이터가 누적되면서 recall regression 패턴이 명확해진 후 자동화 여부를 결정한다.

## 변경 영향 요약

- **변경되는 파일/스킬:**
  - `plugins/knowledge-distillery/skills/mark-evidence/SKILL.md` — Layer 1, Layer 2 흐름 + 5-case idempotency 추가
  - `.github/workflows/mark-evidence.yml` — 변경 없음 (Layer 1을 스킬 내부에 두기로 결정)
  - `plugins/knowledge-distillery/scripts/triage-backtest.sh` — 신규 작성
  - `plugins/knowledge-distillery/scripts/knowledge-gate` — `recent-accepted-prs` 서브커맨드 추가 (backtest 가 vault 에 직접 접근하지 않도록)
  - `plugins/knowledge-distillery/skills/batch-refine/SKILL.md` — Step 1 디스커버리에 `knowledge:deferred` 포함, deferred-only 분기 처리, report 에 Deferred Queue + 운영 Metric 두 섹션 추가
- **변경되지 않는 영역:**
  - batch-refine의 serial 처리 / atomic commit / graceful handoff
  - collect-evidence, extract-candidates, quality-gate 스킬들
  - vault 스키마
  - knowledge-gate CLI

## 결정 로그

- **filter 위치: Stage A (mark-evidence) 선택.** Stage B 진입 시점 필터링 대신 더 이른 시점을 택한 이유는 처리량 문제이지 budget 문제가 아니기 때문. Stage A에서 큐 진입 자체를 막으면 batch-refine의 atomic 보장에 영향 없음.
- **Layer 1은 PoC에서 mark-evidence 내부에 유지.** 이 선택은 Claude Code Action 실행 비용을 없애지는 않지만 구현이 단순하고 Stage B 진입을 줄이는 목적에는 충분하다. 운영 데이터에서 mark-evidence 실행 비용도 병목으로 확인되면 GitHub Actions pre-step으로 승격한다.
- **triage 구성: 하이브리드 선택 (Q2 옵션 B).** 결정론적 규칙만으로는 "docs-only + 결정 신호 없음" 같은 회색 영역을 못 다루고, LLM only는 봇 PR 같은 명백한 경우도 호출 → 비용 손해. 하이브리드가 비용/커버리지 균형 최적.
- **mini-batch 전환은 별도 PR.** 가치는 인정되나 본 설계 범위를 넘어선다.
- **레포별 규칙 외부화는 YAGNI.** 첫 운영 1주일 결과 데이터 본 뒤 결정.
