# Knowledge Distillery

**AI 코딩 에이전트에게 검증된 지식만 전달하는 시스템.**

[English](../../README.md) | [한국어](./README.md)

---

## 문제

AI 코딩 에이전트에게 필터링되지 않은 컨텍스트를 대량으로 제공하면, 더 똑똑해지는 것이 아니라 더 시끄러워집니다. 검증되지 않은 가설이 사실로 취급되고, 철회된 결정이 지시로 남아있으며, 무관한 정보가 핵심 규칙을 묻어버립니다. 결과는 환각, 조용한 실수, 비용이 큰 재작업입니다.

## 접근 방식

Knowledge Distillery는 다른 길을 택합니다: **넓게 수집하고, 엄격하게 정제하고, 최소한으로 전달합니다.**

Convention 기반 에어갭을 갖춘 3계층 아키텍처가 날것의 정보와 검증된 지식을 구조적으로 분리합니다:

1. **히스토리 보관소** — 날것의 데이터를 손실 없이 보존 (Slack, Linear, PR 리뷰, AI 세션 트랜스크립트)
2. **정제 파이프라인** — 자동 품질 게이트를 갖춘 AI 자율 정제. 확정된 결정과 검증된 안티패턴만 추출
3. **지식 금고** — 증류된 인사이트의 SQLite 저장소. `knowledge-gate` CLI를 통해서만 접근 가능

에이전트는 날것의 데이터에 절대 접근하지 않습니다. 정제를 통과한 것만 봅니다.

## 핵심 설계 결정

- **Convention 기반 에어갭**: 날것의 데이터와 에이전트 동선 사이의 운영적 격리 — 완벽한 기술적 차단이 아니라 충분하고 현실적인 수준
- **AI 자율 정제**: LLM이 추출하고 압축하며, 인간은 항목별 승인이 아닌 전략적 감독을 수행
- **컨텍스트 관문**: 도메인 기반 선별적 필터링으로 에이전트에게 현재 작업에 관련된 지식만 전달
- **Append-only, 두 가지 유형만**: 금고에는 **Fact**와 **Anti-Pattern**만 존재 — 확신도 점수 없음, 애매함 없음

## 문서

파이프라인 동작의 source of truth는 `plugins/knowledge-distillery/skills/`에 있는 실행 가능한 Skill들이다.

| 문서 | 설명 |
|---|---|
| [설계 철학](design-philosophy.md) | 이 아키텍처가 존재하는 이유 — AI 에이전트를 위한 정보 통제의 근거 |
| [구현 설계서](design-implementation.md) | 어떻게 작동하는가 — 파이프라인 설계, 금고 스키마, 런타임 정책, Claude Code Plugin 배포 |
| [도입 가이드](adoption-guide.md) | plugin 설치, 저장소 초기화, vault 사용 시작 절차 |
| [도구 검토 결과](tool-evaluation.md) | 채택/불채택 도구와 근거 |

## CLI 빠른 참조

`knowledge-gate` CLI는 지식 금고(`.knowledge/vault.db`)의 유일한 접근 경로다. `KNOWLEDGE_VAULT_PATH`로 기본 금고 경로를 변경할 수 있다.

**에이전트 런타임** — 코드 수정 전 규칙 조회:

| 커맨드 | 용도 |
|---|---|
| `query-paths <filepath>` | 파일 경로를 도메인으로 해소 → 매칭 규칙 반환 |
| `query-domain <domain>` | 도메인 이름으로 규칙 조회 |
| `search <keyword>` | FTS5 전문 키워드 검색 |
| `get <id>` | 항목 전체 상세 조회 (body 포함) |
| `list` | 활성 항목 요약 목록 (탐색/키워드 발견용) |

**도메인** — 도메인 레지스트리 탐색 및 관리:

| 커맨드 | 용도 |
|---|---|
| `domain-info <domain>` | 도메인 상세 (설명, 패턴, 항목 수) |
| `domain-list [--status X] [--ids-only]` | 도메인 목록 또는 경량 도메인 ID 인덱스 출력 |
| `domain-resolve-path <filepath>` | 파일 경로 → 도메인 역조회 |
| `domain-add`, `domain-merge`, `domain-split`, `domain-deprecate` | 레지스트리 생애주기 |
| `domain-paths-set`, `domain-paths-add`, `domain-paths-remove` | 경로 패턴 관리 |
| `domain-report` | 도메인 상태 진단 |

**적재** — 금고에 항목 추가:

| 커맨드 | 용도 |
|---|---|
| `add --type <type> --title ... --claim ... --body ... --domain ... [플래그]` | 검증 후 항목 추가 |
| `_pipeline-insert` | 파이프라인 전용 일괄 INSERT (JSON stdin) |

**유틸리티** — 셋업 및 유지보수:

| 커맨드 | 용도 |
|---|---|
| `init-db [path]` | 번들된 schema로 새 vault 생성 |
| `migrate` | 스키마 마이그레이션 적용 |
| `doctor` | 저장소 도입 상태 검증 |
| `curate` | 인터랙티브 큐레이션 큐 해소 |

**예시:**

```bash
# 파일 수정 전 규칙 조회
knowledge-gate query-paths src/api/auth/login.ts

# 파일이 어떤 도메인에 속하는지 확인
knowledge-gate domain-resolve-path src/services/payment.rb

# 탐색용 경량 도메인 ID 인덱스 preload
knowledge-gate domain-list --ids-only

# 키워드로 규칙 검색
knowledge-gate search "callback"
```

자세한 사용법은 `knowledge-gate help`를 실행한다.

## 배포 형태

**Claude Code Plugin**으로 배포합니다 — `claude plugin install`로 설치하면 런타임 Skill, 파이프라인 Skill, 번들된 schema 자산, `knowledge-gate` CLI가 일체로 제공됩니다. CLI 자체는 벤더 중립(`sqlite3` 기반)이며, 어떤 코딩 에이전트에서든 실행 가능합니다.
레포지토리가 marketplace를 겸한다. `.claude-plugin/marketplace.json`이 marketplace를 선언하고, 플러그인 자체는 `plugins/knowledge-distillery/` 하위에 `plugin.json`, `skills/`, `scripts/`, `schema/`와 함께 위치한다.

## 상태

Proof of concept. 설계는 의도적으로 변경에 열려 있습니다 — 엄격한 제약과 빈틈없는 방어 장치는 향후 반복을 어렵게 만듭니다. 실제 사용성 경험에 우선 집중합니다.

## 라이선스

TBD
