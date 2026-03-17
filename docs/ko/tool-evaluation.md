# 도구 검토 결과  

> **평가 기준 (설계 철학/구현과의 정합성)**
>
> 1. **자동 품질 게이트 호환성**: 도구의 출력이 정제 후보 필수 스키마([설계 구현 §3.3](./design-implementation.md#33-정제-후보-필수-스키마))를 충족하거나 변환 가능한가
> 2. **에어갭 원칙 준수**: 에이전트가 원시 데이터에 직접 접근하지 않는 구조를 유지하는가
> 3. **배치 파이프라인 적합성**: 실시간이 아닌 주기적 배치 정제와 양립하는가
> 4. **벤더 중립성**: 특정 코딩 에이전트(Claude Code, Codex, Gemini 등)에 종속되지 않고 범용적으로 적용 가능한가
> 5. **복잡성 대비 이득**: 도입 비용(인프라, 학습, 유지보수)이 이득을 초과하지 않는가
> 6. **거절 코드(R1/R3/R5/R6) 지원**: 자동 품질 게이트의 검증 기준을 도구가 지원하거나 방해하지 않는가

## A.1 채택  
  
| 도구 | 적용 위치 | 역할 | 현황 |  
|---|---|---|---|  
| [obra/claude-memory-extractor](https://github.com/obra/claude-memory-extractor) | Layer 2 (프롬프트 설계) | 직접 통합 아님. 다차원 추출 프롬프트 구조를 시스템 프롬프트 설계 시 참고 | ⚠️ 2025-09 이후 커밋 없음 |  
| [obra/cc-plugin-decision-log](https://github.com/obra/cc-plugin-decision-log) | Layer 2 (템플릿 설계) | Decision/Approach 구조를 Evidence Bundle 및 지식 금고 템플릿에 차용 | 실험적 (obra 개인 프로젝트) |  
| [Agent Trace](https://github.com/cursor/agent-trace) (스키마 차용) | Layer 2 (증거 추적) | `evidence` 필드의 출처 추적 스키마 참고. 라인 수준 코드 귀속 표준 | RFC v0.1.0 (Cursor 주도) |  
| [SKILL.md](https://agentskills.io) | Layer 3 (배포 형식 — 구현 배치) | 지식 금고 결과물을 에이전트 스킬 파일로 배포/재사용하는 표준 형식. 방향 채택, 구현은 본 설계 범위 이후 | 업계 표준화 진행 중 |
| [git-memento](https://github.com/mandel-macaque/memento) | Layer 1 (세션 캡처) | AI 코딩 세션 트랜스크립트를 git notes로 커밋에 부착. Evidence Bundle의 핵심 입력 | 활발 (mandel-macaque 주도) |
| [SQLite](https://sqlite.org) | Layer 3 (저장소 + 컨텍스트 관문) | 지식 금고의 단일 저장소 + knowledge-gate CLI의 쿼리 엔진 | 세계에서 가장 널리 배포된 DB |
  
### claude-memory-extractor  
  
다차원 추출 구조(Five Whys, 심리적 동기, 예방 전략, 불확실성 표기)를 정제 프롬프트 설계에 참고한다. 특히 "confidence가 낮으면 억지로 교훈을 만들지 말 것"이라는 제약이 본 설계의 원칙과 일치한다 (confidence는 정제 파이프라인 내부 도구로만 사용되며, 지식 금고에는 기록되지 않는다.). Node.js/TypeScript 기반 Claude CLI 로컬 로그 전용이므로 직접 통합이 아닌 프롬프트 패턴 차용. **2025-09 이후 커밋이 없어 장기적으로 포크 또는 대안이 필요할 수 있다.**  
  
### cc-plugin-decision-log (신규)  
  
Claude Code 플러그인으로, 코딩 세션 중 의사결정을 구조화하여 로깅한다. `Decision` (topic → options → chosen → rationale)과 `Approach` (approach → outcome[failed/succeeded] → details) 구조가 핵심이다.  
  
**활용 방식:**  
- `Decision.options` + `Decision.chosen` 구조 → Evidence Bundle에서 "고려한 대안 vs 선택한 접근"을 명시적으로 캡처  
- `Approach.outcome: failed` → Anti-Pattern 후보의 "실패했던 접근" 섹션과 직접 대응  
- "검색 후 결정하라(search before deciding)" 패턴 → 정제 프롬프트에서 기존 지식 금고를 먼저 조회하도록 강제  
  
직접 통합이 아닌 데이터 구조와 패턴 차용이므로 플러그인 자체의 성숙도와 무관하게 활용 가능하다.  
  
### Agent Trace (신규 — 스키마 차용)  
  
Cursor가 주도하고 Cognition(Devin), Vercel, Cloudflare, Google Jules, OpenCode 등이 참여하는 AI 코드 귀속 표준(RFC v0.1.0). 파일/라인 수준에서 어떤 AI 모델과 대화가 해당 코드를 생성했는지 추적한다.  
  
**활용 방식:**  
- `evidence` 필드의 출처 추적 구조를 Agent Trace 스키마에서 참고  
- `conversation.url` → Slack/Linear 링크, `related` → PR/이슈 연결  
- 콘텐트 해시 기반 코드 이동 추적이 유효성 검증([설계 구현 §5.2](./design-implementation.md#52-인간-큐레이션-ux))에 유용할 수 있음  
  
현재 RFC 단계이므로 스키마 설계 참고 수준으로 활용하고, 정식 릴리스 후 직접 통합을 재검토한다.  

### git-memento (신규 — Layer 1 세션 캡처 인프라)

AI 코딩 세션의 트랜스크립트를 `git notes`로 커밋에 부착하여 "왜 이렇게 변경했는가"의 맥락을 보존하는 CLI 도구. Knowledge Distillery의 Layer 1(원시 데이터 호수) 핵심 인프라로 채택했다.

**채택 사유:**

| 평가 항목 | 판단 |
|---|---|
| Evidence Bundle 기여 | 커스텀 Summary Skill로 구조화된 요약이 Evidence Bundle의 AI 세션 컨텍스트로 직접 포함 |
| 에어갭 호환성 | `git notes`는 명시적 refspec 없이 fetch되지 않으므로 에어갭이 자연 유지 |
| squash merge 생존 | `notes-carry` 명령으로 개별 커밋 노트를 머지 커밋에 이관. GitHub Action 자동화 지원 |
| CI 게이트 | `audit --strict`로 노트 미부착 커밋 검증. PR 게이트로 활용 가능 |

설계 구현 §2.5에 상세 사양(저장 구조, 보존 정책, 커스텀 Summary Skill 등)을 정의한다.

### SQLite (신규 — 지식 금고 저장소 + 컨텍스트 관문)

지식 금고의 **유일한 저장소**이자 컨텍스트 관문(knowledge-gate CLI)의 쿼리 엔진으로 채택했다. Markdown + YAML frontmatter 이중 포맷 관리를 제거하고, SQLite 단일 파일로 통합한다.

**채택 사유:**

| 평가 항목 | 판단 |
|---|---|
| 사전 설치율 | macOS(`/usr/bin/sqlite3`), 대부분의 Linux에 기본 탑재. 의존성 zero |
| 컨텍스트 관문 강제 | 바이너리 포맷이라 LLM이 `Read`해도 무의미 → knowledge-gate CLI를 통해서만 접근 가능. 컨텍스트 관문의 구조적 강제 ([설계 구현 §4.1](./design-implementation.md#41-저장-위치-및-형식) 참조) |
| 벤더 중립성 | 모든 코딩 에이전트(Claude Code, Codex, Gemini 등)가 셸 명령으로 `sqlite3` 실행 가능 |
| 쿼리 능력 | 표준 SQL + FTS5 전문 검색 + 인덱스 기반 조회. LLM이 가장 잘 아는 쿼리 언어 |
| 스키마 강제 | `CHECK`, `NOT NULL`, `FOREIGN KEY`로 정제 파이프라인 출력의 정합성을 DB 레벨에서 보장 |
| 배포 | 단일 `.db` 파일을 master 브랜치에 커밋. `git pull`만으로 최신 지식 금고 사용 가능 |

**Git diff 불가에 대한 입장:** 지식 금고 문서의 변경은 정제 파이프라인(LLM)이 전담하므로 인간이 diff를 볼 필요가 없다. 변경 이력이 필요하면 `sqlite3`로 `created_at` 기준 조회하거나 DB 내 상태(`active`/`archived`)와 `archive_reason`으로 추적한다.

**대안 비교:** §A.5 지식 금고 저장소 + 컨텍스트 관문 도구 비교 참조.

### SKILL.md (신규)  
  
AI 코딩 에이전트가 필요 시점에 로드할 수 있는 재사용 가능 역량 패키지 표준. Claude Code, Cursor, Gemini CLI 등 27개 이상의 에이전트가 지원한다. 에이전트는 시작 시 ~100 토큰의 설명만 로드하고, 작업이 매칭되면 전체 지시사항을 lazy-load한다.  
  
**활용 방식:**
- YAML frontmatter(id, name, description) + Markdown 본문으로 기존 지식 금고 템플릿과 호환
- 지식 금고의 "소비 형식"을 표준화하는 데 적합. 본 설계 범위 이후 구현을 검토한다

**제약 — 컨텍스트 관문을 대체하지 않는다:**
지식 금고의 항목을 SKILL.md로 내보내 파일시스템에 배치하면, 에이전트가 모든 스킬 파일을 직접 읽을 수 있게 되어 컨텍스트 관문의 선별적 필터링이 무력화된다. 지식 금고에는 프로젝트 전체에 걸친 다양한 도메인의 규칙이 축적되며, 그 총량은 어떤 단일 작업에도 전부 필요하지 않다. 파일 기반 전달은 현재 작업과 무관한 규칙까지 컨텍스트에 적재시켜, 관련성을 통제하지 않은 정보 증가로 인한 성능 저하를 초래한다([설계 철학 §1](./design-philosophy.md#1-정보의-홍수는-지식이-아니라-소음이-된다), [§4.4](./design-philosophy.md#44-컨텍스트-관문--선별적-노출)). 따라서 SKILL.md는 knowledge-gate CLI가 없는 환경에서의 fallback이나, Knowledge Distillery를 채택하지 않은 프로젝트와의 호환을 위한 **보조 배포 형식**이며, 컨텍스트 관문을 통한 선별적 전달을 대체하지 않는다.  
  
---  
  
## A.2 불채택  
  
| 도구 | 불채택 사유 | 현황 (2026-03) |  
|---|---|---|  
| [Fabric](https://github.com/danielmiessler/fabric) | Claude Code 네이티브 경로에서 Skill이 곧 추출 프롬프트이고 LLM이 자기 자신이므로, 별도 프롬프트 러너인 Fabric이 제공하는 가치가 없다. Go 바이너리 의존성, 별도 API 키 설정, 출력 파싱 접착 코드, Rake 오케스트레이션 등 불필요한 복잡도만 추가 | ✅ 활발 (39k+ stars). 도구 자체의 문제가 아닌 아키텍처 적합성 사유 |
| [Log4brains](https://github.com/thomvaill/log4brains) | 지식 금고가 SQLite 단일 파일로 전환되어 ADR Markdown 탐색 도구의 적용점이 소멸. 큐레이션 UI 역할은 A.6 참조 | ⚠️ 2024-12 이후 개발 정체 |
| Zep / Graphiti | 지식 금고는 의도적으로 단순한 SQLite 단일 파일. 그래프 DB 도입은 과잉 복잡성 | MCP 지원 추가됨. 연결 편의성은 개선되었으나 근본적 복잡성은 유지 |
| Hindsight | "정제 파이프라인 통과 = 금고 존재 자격" 원칙(confidence 필드를 금고에 남기지 않음)과 철학적 충돌. Hindsight의 Temporal+Semantic 메모리는 확률적 가중치를 유지하는데, 이는 본 설계의 "통과/탈락 이분법"과 다른 모델 | vectorize-io/hindsight로 활발 개발 중 (Temporal+Semantic+Entity 메모리). 철학적 차이는 여전 |  
| Mem0 | 자동화된 메모리 병합은 "자동 품질 게이트 기준을 충족한 항목만 승격" 원칙과 상충. 품질 게이트 기준(R1/R3/R5/R6)을 우회하는 자동 병합은 불확실한 정보의 금고 유입을 허용한다 | v1.0.0 릴리스, MCP 서버 + 플랫폼 UI 추가. 관리형 서비스 지향으로 방향 전환 |  
| Obsidian / Logseq | 에이전트용 지식 금고는 레포 내 마크다운이어야 하므로 별도 볼트 관리가 불필요한 간접 레이어 | 변동 없음 |  
| Microsoft GraphRAG | 정제 품질 향상 가능성은 있으나, Python 전용 + 높은 LLM 비용 + 복잡한 인프라로 현 설계의 단순성 원칙에 부적합 | v3.0.5 (2026-03), 31k+ stars. DRIFT Search, LazyGraphRAG 등 신기능 추가 |  
  
### Microsoft GraphRAG (신규 — 불채택)  
  
Leiden 알고리즘 기반 커뮤니티 클러스터링 + LLM 요약으로 계층적 지식 그래프를 구축한다. Local/Global/DRIFT 세 가지 쿼리 모드를 지원하며, 코드 의존성 분석 등 소프트웨어 엔지니어링 활용 사례도 증가하고 있다.  
  
**불채택 사유:**  
- **인프라 복잡성:** Python 3.10+ 전용, Parquet/Azure Blob Storage, pandas/networkx 의존. Claude Code 네이티브 파이프라인과 이질적  
- **LLM 비용:** 인덱싱 과정에서 모든 청크를 다중 처리(추출+요약)하므로 비용이 높음  
- **출력 형식:** Parquet/CSV 테이블 출력 → Markdown+YAML 변환 레이어 필요  
- **배치 호환성:** 주기적 인덱싱 자체는 배치 파이프라인과 호환되나, 전체 도입 비용이 이득을 초과  
  
경량 대안으로 [nano-graphrag](https://github.com/gusye1234/nano-graphrag)가 있다. 핵심 Leiden 클러스터링 + 요약 로직을 단순화한 구현체. → A.3 추가 검토 대상으로 기록.  
  
### Letta (구 MemGPT) — 불채택 유지, 재검토 여지 있음  
  
2026년 Letta로 리브랜딩하며 **Context Repositories** (Git-based Memory) 기능을 도입했다. Git 기반 메모리 버전 관리로, 모든 메모리 변경에 커밋 메시지가 붙는다. 이는 본 설계의 "감사 가능한 배치 정제"와 방향이 유사해졌다.  
  
**불채택 유지 사유:**  
- 여전히 에이전트 런타임 레벨 솔루션이 핵심이며, 빌드타임 배치 정제와는 레이어가 다름  
- Context Repositories는 흥미하지만 현재 Letta 플랫폼 내부 기능으로, 독립 사용이 제한적  
  
**재검토 조건:** Context Repositories가 독립 라이브러리로 분리되거나, Git-backed 메모리 관리를 외부에서 활용할 수 있게 되면 재검토.  
  
---  
  
## A.3 추가 검토 대상  
  
| 항목 | 검토 포인트 | 현재 상태 |  
|---|---|---|  
| nano-graphrag | GraphRAG의 경량 대안. Leiden 클러스터링 + 요약을 단순화한 구현체 | 후속 비교 검토 예정 |
| sqlite-graph | SQLite 그래프 확장. file_scopes 경로 폭발 문제에 대한 그래프 모델 해결책 후보 | Alpha v0.1.0 — 핵심 기능 미성숙, 안정화 후 재검토 |  
| Client-Side RAG (GitNexus 등) | 에어갭 원칙을 유지한 로컬 RAG. 지식 금고 검색 품질 개선 가능성 | 후속 비교 검토 예정 |  
| claude-mem | Claude Code 관찰을 CLAUDE.md로 증류하는 플러그인. 본 설계의 정제 파이프라인과 접근이 유사 | 후속 비교 검토 예정 |  
| Beads | 코딩 에이전트 세션 간 영속적 메모리. 크로스세션 상태 유지 패턴 참고 가능 | 후속 비교 검토 예정 |  
| cursor-memory-bank | 큐레이트된 Markdown 파일로 에이전트에 지식 제공. 본 설계의 지식 금고 패턴과 동일 계열 | 후속 비교 검토 예정 |  
| ICM (rtk-ai/icm) | `init` 부트스트랩과 CLI 계층화는 참고 가치가 있으나, 에이전트 직접 메모리 쓰기 모델은 에어갭 원칙과 충돌 | 개념 패턴만 참고 (라이선스 제약으로 직접 차용 불가) |
  
### nano-graphrag (신규)  
  
[gusye1234/nano-graphrag](https://github.com/gusye1234/nano-graphrag). Microsoft GraphRAG의 핵심 로직(커뮤니티 탐지 + 요약)을 경량화한 구현체. 출력 형식 커스터마이징이 쉬워 Markdown+YAML 변환이 가능할 수 있다. GraphRAG의 정제 품질 향상 가능성을 낮은 도입 비용으로 검증하는 데 적합하다.  
  
### Client-Side RAG (신규 — 상세 검토)  
  
[GitNexus](https://github.com/abhigyanpatwari/GitNexus)는 브라우저/로컬에서 동작하는 "Zero-Server Code Intelligence Engine"으로, Transformers.js 로컬 임베딩 + IndexedDB 벡터 저장소를 사용한다. 외부 API 호출 없이 지식 금고를 검색할 수 있어 에어갭 원칙과 호환된다.  
  
**검토 포인트:**  
- 로컬 임베딩 모델(all-MiniLM-L6-v2 등)을 번들링하면 네트워크 호출 없이 인덱싱/검색 가능  
- CLI 기반 대안으로 gptme-rag, DocuPulse 등 경량 도구가 존재  
- 지식 금고가 커질 때 Markdown 파일 대상 시맨틱 검색이 유효성 검증 품질을 높일 수 있음  
- 라이선스 확인 필요 (일부 도구가 비상업 라이선스를 사용)  

### claude-mem (신규)

[thedotmack/claude-mem](https://github.com/thedotmack/claude-mem). Claude Code 세션의 관찰 내용을 압축하여 `CLAUDE.md`에 증류하는 플러그인. Agent SDK를 활용한 자동 압축 메커니즘이 본 설계의 "결정된 결과에서 결론을 증류"하는 정제 파이프라인과 접근이 유사하다. 다만 단일 세션 스코프이며, 배치 정제 + 자동 품질 게이트 구조와는 적용 레이어가 다르다. 정제 프롬프트 설계 시 압축 전략을 참고할 수 있다.

### sqlite-graph (신규)

[agentflare-ai/sqlite-graph](https://github.com/agentflare-ai/sqlite-graph). SQLite에 그래프 DB 기능(노드/엣지 + Cypher 쿼리)을 추가하는 C99 확장. 순수 C로 외부 의존성이 없으며, `CREATE VIRTUAL TABLE graph USING graph()`로 기존 SQLite DB 안에 그래프 레이어를 생성한다.

**검토 배경:** 지식 금고 스키마의 초기 모델이었던 `file_scopes`(Entry ↔ Path 직접 매핑)는 횡단 관심사 규칙에서 경로가 폭발하는 구조적 한계가 있어, 현행 도메인 모델(`domain_registry` + `domain_paths` + `entry_domains`)로 대체되었다([설계 구현 §4.5](./design-implementation.md#45-도메인-레지스트리-생애주기) 참조). 그래프 모델로 Entry → Concept → Path 중간 계층을 도입하면 이 문제가 해소되며, sqlite-graph은 SQLite 단일 파일 배포 모델을 유지하면서 그래프 쿼리를 제공할 수 있는 후보다.

**현재 상태 (v0.1.0-alpha.0):**

| 항목 | 상태 |
|---|---|
| Cypher CREATE/MATCH/WHERE/RETURN | 지원 |
| 복합 WHERE (AND/OR/NOT) | **미지원** (v0.2.0 예정) |
| 가변 길이 경로 (`[r*1..3]`) | **미지원** (v0.2.0 예정) |
| Aggregation (COUNT, SUM 등) | **미지원** |
| Property projection (`n.property`) | **미지원** |
| macOS | 빌드 가능, 제한적 테스트 |
| 테스트 규모 | 1,000 노드까지만 검증 |

**현 시점 불채택 사유:**
- Alpha 단계로 "not recommended for production" 명시
- 복합 WHERE와 가변 길이 경로 미지원은 2-hop 쿼리(Path → Concept → Entry)에 치명적
- macOS 지원이 제한적 (개발 환경 호환성 리스크)
- 순수 SQL JOIN 테이블(`concepts`, `entry_concepts`, `concept_scopes`)로도 동일한 중간 계층 모델을 구현할 수 있어 그래프 확장 없이 핵심 가치를 확보 가능

**재검토 조건:** v0.2.0+ 안정화 이후 복합 WHERE, 가변 길이 경로, macOS 정식 지원이 확인되고, 순수 SQL JOIN으로 감당하기 어려운 3-hop 이상의 그래프 탐색이 필요해지는 시점에 재검토.

### cursor-memory-bank (신규)

[vanzan01/cursor-memory-bank](https://github.com/vanzan01/cursor-memory-bank). 큐레이트된 Markdown 파일 세트(VAN, PLAN, CREATIVE, IMPLEMENT)로 에이전트에 영속적 컨텍스트를 제공하는 프레임워크. "에이전트는 큐레이트된 금고만 참조" 패턴이 본 설계의 지식 금고와 동일한 계열이다. 다만 수동 큐레이션 전제이며, 자동 정제 파이프라인과의 통합은 미고려.

### ICM (rtk-ai/icm) — `init` / CLI 구조 개념 참고

[rtk-ai/icm](https://github.com/rtk-ai/icm)은 "single binary, zero dependencies, MCP native"를 내세우는 에이전트 메모리 시스템이다. 전체 제품으로서는 런타임 메모리 시스템에 가깝고, 에이전트가 직접 메모리를 저장·수정·삭제하는 구조이므로 지식 에어갭/배치 정제 중심인 본 설계와는 핵심 철학이 다르다. 다만 공개 문서에 드러난 **초기 셋업 UX**와 **CLI 명령 계층 분리**는 벤더 중립 런타임 CLI를 지향하는 우리 설계에 참고 가치가 있다.

**공개 문서에서 확인한 구조:**
- `icm init` 한 번으로 Claude Code, Cursor, Codex CLI, OpenCode 등 다수 클라이언트의 MCP 설정 파일을 자동 감지·수정
- `icm init --mode skill`로 MCP 등록과 별도로 slash command / rule 설치를 분리
- `icm serve`를 MCP 서버 진입점으로 두고, 별도의 CLI 계층에서 `store`, `recall`, `forget`, `consolidate`, `stats`, `config`, `memoir ...` 등을 제공
- `health`/`stats`류 운영 점검 커맨드와 `config` 노출을 별도 관리 계층으로 둠

이 구조는 "설치/부트스트랩", "에이전트 런타임 조회", "운영 관리", "서버 진입점"을 분리한 명령 체계로 요약할 수 있다. Knowledge Distillery에도 이 분리 자체는 유효하지만, 각 계층의 책임은 에어갭 원칙에 맞게 다시 정의해야 한다.

**차용할 부분 (개념만):**
- **원샷 멀티클라이언트 부트스트랩:** Claude plugin을 설치한 뒤 `/knowledge-distillery:init` 같은 단일 도입 단계로 이어지는 UX는 도입 가치가 높다. 우리 설계는 [설계 구현 §7.5](./design-implementation.md#75-컨텍스트-관문-knowledge-gate-skill--cli)의 "Claude-first(배포) / 벤더 중립(런타임)"을 지향하므로, 런타임 데이터 경로는 공통 `knowledge-gate`로 유지하고 설치 UX만 에이전트별로 조정하는 구성이 적절하다.
- **설치 모드 분리:** 플러그인/런타임 설치와 프로젝트 도입 설정을 분리하는 패턴은 그대로 유용하다. 이 설계에서는 플러그인 설치가 `skills/`, `scripts/`, `schema/`를 제공하고, `/knowledge-distillery:init`이 저장소 내부의 vault 생성과 workflow 설정 같은 도입 작업을 수행한다.
- **CLI 계층 명확화:** 현재 `knowledge-gate`는 조회/도메인 관리/파이프라인 후처리가 한 문서에 공존한다. 장기적으로는 `agent runtime` (`query-paths`, `query-domain`, `search`, `get`), `pipeline/admin` (`_pipeline-insert`, `domain-*`, `migrate`), `diagnostics` (`doctor`, `domain-report`, 향후 `vault-health`, `vault-stats`)를 더 뚜렷하게 나누는 편이 사용성과 문서 탐색성이 좋다.
- **진단 커맨드 강화:** 인간의 전략적 감독 역할([설계 철학 §6.3](./design-philosophy.md#63-인간의-역할-개별-항목의-승인자가-아니라-전략적-감독자))에 맞춰, 향후 `vault-health` 계열 커맨드를 추가하는 것은 타당하다. 후보 항목으로는 도메인 과밀/과소, 고아 도메인, archived 비율, 중복 가능 항목, 현재 `knowledge:pending` 백로그 현황 등이 있다.
- **설정 가시성:** 현재도 CLI 스펙은 명확하지만, 실행 중인 금고 경로와 활성 설정을 빠르게 점검하는 `config`/`doctor` 류 커맨드는 운영 편의 측면에서 도움이 된다. 특히 "왜 이 에이전트가 knowledge-gate를 못 찾는가" 같은 설치 문제를 진단하는 계층이 있으면 플러그인 배포 품질이 올라간다.

**차용하지 않을 부분:**
- 에이전트가 런타임에 지식 저장소를 직접 수정하는 `store` / `update` / `forget`류 쓰기 경로
- 세션 훅(PostToolUse, SessionStart, PreCompact)에서 곧바로 메모리를 생성·주입하는 자동 추출 구조
- decay/consolidation을 authoritative knowledge 자체의 수명 관리 규칙으로 사용하는 방식
- 메모리 시스템을 제품의 중심으로 두고, 배치 정제 파이프라인을 부수화하는 구조

**우리 쪽 반영 방향:**
- `knowledge-gate`는 계속 **유일한 런타임 접근 경로**로 유지한다 ([설계 구현 §7.5](./design-implementation.md#75-컨텍스트-관문-knowledge-gate-skill--cli)).
- 차용 대상은 설치 UX와 운영 UX뿐이며, 지식 생성/승격 경로는 계속 [설계 구현 §3.1](./design-implementation.md#31-트리거-2단계-파이프라인)의 2단계 정제 파이프라인을 따른다.
- `knowledge-gate doctor`는 이제 도입 검증용 보조 인터페이스로 사용할 수 있다. 향후에는 `knowledge-gate vault-health` 같은 추가 진단 커맨드를 검토할 수 있지만, 이들도 모두 **금고 쓰기 권한을 부여하지 않는 보조 인터페이스**여야 한다.

**라이선스 주의:**
[ICM 라이선스](https://github.com/rtk-ai/icm/blob/main/LICENSE)는 source-available이며 `NO COPYING OR REDISTRIBUTION`, `NO DERIVATIVE WORKS`를 명시한다. 따라서 이 프로젝트에서는 ICM의 코드, 문구, 설정 템플릿을 재사용하지 않고, 공개적으로 드러난 제품 아이디어와 UX 패턴만 개념 수준에서 참고한다.  
참고 문서: [README](https://github.com/rtk-ai/icm/blob/main/README.md), [LICENSE](https://github.com/rtk-ai/icm/blob/main/LICENSE)
  
---  
  
## A.4 리서치 자료  
  
설계의 이론적 근거로 참고한 논문 및 가이드.  
  
| 자료 | 핵심 개념 | 반영 위치 |  
|---|---|---|  
| [Lost in the Middle](https://arxiv.org/abs/2307.03172) (2023) | 긴 컨텍스트 중간에 묻힌 정보의 성능 저하 | 위치 편향 대응: TL;DR 상단 배치 + 하단 재기재 ([설계 구현 §4.3](./design-implementation.md#43-출력-포맷)) |  
| [Context Rot](https://research.trychroma.com/context-rot) | 입력 길이 증가에 따른 성능 불안정 | "추가에 보수적" 원칙의 이론적 근거 |  
| [Distraction in Long Context](https://arxiv.org/abs/2404.08865) (2024) | 무관 정보에 의한 주의 분산 효과 | 지식 에어갭 존재 이유 — 정보 가치가 낮은 정보를 에이전트에게서 차단 |
| [Do Context Files Help Coding Agents?](https://arxiv.org/abs/2602.11988) (2025, ETH Zürich) | 컨텍스트 파일이 에이전트 성공률을 오히려 감소시키고 추론 비용을 20%+ 증가시킨 실증 결과. 불필요한 요구사항을 따르느라 핵심 코드에 도달하지 못하는 현상 | 컨텍스트 관문의 선별적 노출이 필수인 이유 — 파일 기반 전달(SKILL.md 등)이 컨텍스트 관문을 대체할 수 없는 근거 ([설계 철학 §4.4](./design-philosophy.md#44-컨텍스트-관문--선별적-노출)) |
| Anthropic 컨텍스트 엔지니어링 원칙 | Attention budget 하 정보 가치가 높은 토큰의 최소 집합 | 전체 운영 철학의 기반 |  
  
---  
  
**공통 판단 기준:** "자동 품질 게이트(R1/R3/R5/R6)로 검증된 항목만 승격하고, 인간은 전략적으로 감독하며, 추가에 보수적" 원칙과의 정합성. 이 원칙에 맞지 않거나 복잡성 대비 이득이 부족한 도구는 불채택.

---

## A.5 지식 금고 저장소 + 컨텍스트 관문 도구 비교

지식 금고의 저장소 형식과 에이전트의 접근 메커니즘(컨텍스트 관문)을 결정하기 위해 검토한 후보들이다.

### 검토 배경

컨텍스트 관문은 에이전트 세션 시작 시점마다 "무엇을 읽히고 무엇을 제외할지"를 결정하는 필터다. 핵심 요구사항:

1. **벤더 중립**: Claude Code, Codex, Gemini 등 모든 코딩 에이전트에서 동작
2. **컨텍스트 관문 강제**: 에이전트가 지식 금고를 직접 읽지 못하도록 기술적으로 강제 (CLI를 통한 선별적 접근만 허용)
3. **파일 경로 기반 매칭**: PR에서 수정된 파일 경로로 관련 규칙을 자동 조회
4. **전문 검색**: 키워드로 관련 규칙을 탐색
5. **최소 의존성**: 추가 설치 없이 사용 가능

### 후보 비교

| | **SQLite** (채택) | **JSON + jq** | **DuckDB** | **`.claude/rules/`** |
|---|---|---|---|---|
| **사전 설치** | macOS/Linux 기본 탑재 | jq는 별도 설치 필요 | 별도 설치 필요 (~20-30MB) | Claude Code 전용 |
| **컨텍스트 관문 강제** | 바이너리 → LLM Read 무의미 | 텍스트 → LLM이 직접 Read 가능 | 바이너리 → Read 무의미 | 해당 없음 (항상 로드) |
| **쿼리 언어** | 표준 SQL | jq 표현식 | SQL (PostgreSQL 호환) | glob 패턴 (런타임 자동) |
| **인덱스** | B-tree + FTS5 | 없음 (full scan) | 컬럼 인덱스 | 런타임 glob 매칭 |
| **스키마 강제** | CHECK, NOT NULL, FK | 없음 (schema-free) | CHECK, NOT NULL | YAML frontmatter 컨벤션 |
| **벤더 중립** | 모든 에이전트 (셸 명령) | 모든 에이전트 (셸 명령) | 모든 에이전트 (셸 명령) | **Claude Code 전용** |
| **Git diff** | 불가 (바이너리) | 가능 (텍스트) | 불가 (바이너리) | 가능 (Markdown) |
| **LLM 쿼리 정확도** | 높음 (SQL은 LLM 최숙련) | 중간 (jq 문법 실수 가능) | 높음 (SQL) | 해당 없음 (자동) |

### 불채택 사유 상세

**JSON + jq:**
- git diff 가능이 주요 장점이었으나, 지식 금고 변경을 LLM이 전담하므로 diff 필요성이 해소됨
- 텍스트 파일이라 에이전트가 `Read` 한 번으로 전체 내용을 컨텍스트에 로드할 수 있어 컨텍스트 관문이 무력화됨 — 컨텍스트 관문 강제 불가
- full scan 쿼리로 인덱스를 타지 않음. 지식 금고 규모에서 성능 문제는 없으나, 인덱스를 쓸 수 있는데 안 쓸 이유 없음
- jq 표현식은 SQL보다 LLM이 잘못 작성할 확률이 높음

**DuckDB:**
- JSON 파일을 import 없이 직접 SQL 쿼리 가능한 점이 매력적
- 그러나 사전 설치가 안 되어 있어 추가 의존성 발생 (~20-30MB)
- SQLite가 이미 사전 설치되어 있고 동일한 SQL 쿼리를 지원하므로 DuckDB의 추가 이점이 불충분

**`.claude/rules/` path-scoping:**
- Claude Code 런타임이 `paths` YAML frontmatter의 glob 패턴을 deterministic하게 매칭하여 관련 규칙을 자동 주입하는 빌트인 기능
- 기술적으로 우수하나 **Claude Code 전용** — 다른 코딩 에이전트(Codex, Gemini, OpenCode 등)에서는 동작하지 않음
- 벤더 중립성 요구사항과 충돌하여 주요 메커니즘으로는 불채택
- Claude Code 환경에서는 knowledge-gate CLI와 병행하여 보조적으로 활용 가능

### 최종 결정

**SQLite를 지식 금고의 단일 저장소로 채택.** knowledge-gate CLI(셸 스크립트)가 SQLite를 쿼리하는 유일한 인터페이스이며, 에이전트 스킬(Skill) 파일로 쿼리 프로토콜을 제공한다. 바이너리 포맷이 컨텍스트 관문을 구조적으로 강제하고, 사전 설치율과 SQL 쿼리의 LLM 친화성이 결정적 이점이다.

---

## A.6 지식 금고 큐레이션 클라이언트 참조

지식 금고(vault.db)의 인간 큐레이션([설계 구현 §5.2](./design-implementation.md#52-인간-큐레이션-ux))은 현재 raw SQL SELECT로만 가능하다. SQLite 전용 클라이언트를 활용하면 SSoT를 vault.db에 유지하면서 큐레이션 UX를 개선할 수 있다. 아래는 참조용 도구 목록이다.

### 검토 배경

큐레이션 작업의 핵심 요구사항:
- `entries` 테이블의 상태 전환 (active → archived)
- `curation_queue`의 pending 충돌 쌍 검토 및 해소
- `domain_registry` / `domain_paths` 관리
- FTS5 가상 테이블을 포함한 스키마 탐색
- CHECK 제약, FK, 트리거가 있는 vault.db 구조 호환

### 도구 비교

| | **sqlit** | **SQLiteStudio** | **DB Browser** | **Base** | **datasette** | **TablePlus** | **litecli** |
|---|---|---|---|---|---|---|---|
| **유형** | TUI (터미널) | GUI (데스크톱) | GUI (데스크톱) | GUI (데스크톱) | 웹 UI | GUI (데스크톱) | CLI (터미널) |
| **플랫폼** | 크로스플랫폼 | 크로스플랫폼 | 크로스플랫폼 | **macOS 전용** | 크로스플랫폼 | 크로스플랫폼 | 크로스플랫폼 |
| **라이선스** | OSS | GPL | OSS | 유료 (£29.99) | Apache 2.0 | 프리미엄 ($99+) | BSD-3 |
| **FTS5** | SQL 쿼리로 지원 | 완전 지원 | 완전 지원 | 네이티브/시각적 | **자동 검색 UI** | 시각적 지원 | SQL 쿼리로 지원 |
| **스키마 탐색** | 트리뷰 (트리거/가상테이블) | **ERD 포함 (4.0)** | 기본 | **시각적 인스펙터** | 메타데이터 브라우징 | Structure 뷰 | 자동완성 |
| **인라인 편집** | SQL 생성 방식 | 직접 편집 | 직접 편집 | 직접 편집 | 플러그인 (`write-ui`) | **변경 스테이징** | N/A |
| **팀 공유** | ❌ | ❌ | ❌ | ❌ | **✅ 웹 기반** | ❌ | ❌ |
| **설치** | `pipx install sqlit-tui` | 포터블 바이너리 | 설치 필요 | App Store/직접 | `pip install datasette` | 설치 필요 | `pip install litecli` |

### 개별 도구 상세

#### sqlit — 터미널 파워 유저용 TUI

[Maxteabag/sqlit](https://github.com/Maxteabag/sqlit). "The lazygit of SQL Databases." Python/Textual 기반 TUI 클라이언트.

- **현황:** v1.3.1 (2026-02), ~3.8k stars, 활발한 유지보수
- **편집 방식:** 셀 편집 시 `UPDATE` SQL을 자동 생성하여 쿼리 에디터에 표시 — 실행할 SQL을 직접 확인 가능
- **CLI 모드:** `sqlit query -c "vault" -q "SELECT ..." --format json` — 비대화형 JSON/CSV 출력 지원
- **vault.db 호환:** recursive CTE, 트리거, 가상 테이블 모두 Python `sqlite3` 드라이버로 네이티브 처리
- **큐레이션 적합성:** 단일 사용자, 키보드 중심 워크플로우에 최적. Vim 스타일 키바인딩. 수백만 행 퍼지 검색/필터링

#### SQLiteStudio — 확장 가능한 크로스플랫폼 도구

[sqlitestudio.pl](https://sqlitestudio.pl). C++/Qt 기반, GPL 라이선스.

- **현황:** v3.4.21 (2026-01), 10년+ 개발, 활발한 유지보수. 4.0에서 ERD 에디터 추가 예정
- **커스텀 SQL 함수:** JavaScript, Python, Tcl로 사용자 정의 함수 구현 가능 — 큐레이션 로직(정규식 검증, 텍스트 정리 등)을 SQL 함수로 내장 가능
- **DDL 히스토리:** 스키마 변경 이력 추적 — vault.db 스키마 진화 감사에 유용
- **포터블:** 설치 없이 압축 해제 후 실행. 관리자 권한 불필요
- **큐레이션 적합성:** 복잡한 커스텀 로직이 필요한 파워 유저에 최적. SQLCipher 암호화 지원. 다중 DB 참조 쿼리

#### DB Browser for SQLite — 범용 시각적 브라우저

[sqlitebrowser.org](https://sqlitebrowser.org). 크로스플랫폼 오픈소스.

- **현황:** v3.13.1 (2024-10), 커뮤니티 주도, 안정적이나 릴리스 주기 느림
- **CSV 처리:** 대용량 CSV 임포트/로딩이 다른 도구 대비 가장 견고
- **SQLCipher:** 암호화 DB 지원 우수
- **알려진 이슈:** 대규모 FTS5 인덱스에서 성능 저하 보고. UI가 기능적이나 현대적이지 않음. 일부 사용자에서 안정성 이슈 보고
- **큐레이션 적합성:** 기본적인 데이터 탐색/편집에 적합. 특별한 기능보다는 무난한 범용성

#### Base — macOS 네이티브 SQLite 에디터

[menial.co.uk/base](https://menial.co.uk/base/). Swift/AppKit 네이티브, macOS 전용.

- **현황:** v3.0 (2025-08), 15년+ 개발 역사, 1인 장인(artisan) 개발
- **스키마 인스펙터:** CHECK 제약, FK를 인터랙티브 아이콘으로 시각화 — raw DDL보다 직관적
- **FK 자동 활성화:** 세션에서 `PRAGMA foreign_keys = ON` 자동 적용
- **FTS5:** 네이티브 지원. STRICT 테이블, WITHOUT ROWID, generated columns 포함
- **테이블 리팩토링:** SQLite `ALTER TABLE`의 제약(테이블 재생성 필요)을 GUI로 처리
- **큐레이션 적합성:** macOS 사용자에게 가장 쾌적한 편집 경험. 깔끔하고 빠르고 안정적

#### datasette — 팀 공유 웹 브라우저

[datasette.io](https://datasette.io). Simon Willison 제작, Apache 2.0.

- **현황:** v0.65.2 (stable) / v1.0a9 (alpha), ~10.8k stars, 활발한 유지보수
- **팩싯 브라우징:** status, type 등으로 자동 팩싯 필터 생성 — SQL 없이 항목 탐색
- **FTS5 통합:** FTS5 활성화된 테이블에 자동으로 검색 UI 제공
- **쓰기 지원:** 기본 읽기 전용이나 플러그인으로 확장 가능
  - `datasette-write-ui`: 웹 UI에서 Edit/Insert/Delete 버튼 추가
  - `datasette-auth-passwords`: 쓰기 접근 권한 제어
  - Canned Queries: `metadata.yml`에 특정 UPDATE/INSERT SQL을 웹 폼으로 노출
- **배포:** `datasette vault.db` (로컬), `datasette publish cloudrun` (클라우드), Docker 패키징
- **큐레이션 적합성:** **유일한 팀 공유 옵션.** 여러 큐레이터가 브라우저에서 vault를 탐색/편집해야 할 때 최적

#### TablePlus — 네이티브 멀티 DB 클라이언트

[tableplus.com](https://tableplus.com). 네이티브 구현 (macOS: Swift, Windows: C#).

- **현황:** 활발한 유지보수, macOS/Windows/Linux/iOS 지원
- **가격:** 무료 티어 (탭 2개, 연결 2개 제한) / 유료 $99+ (영구 라이선스, 1년 업데이트)
- **변경 스테이징:** 편집 내용을 즉시 반영하지 않고 "코드 리뷰"처럼 SQL 미리보기 후 커밋 — 안전한 큐레이션
- **Safe Mode:** 프로덕션 DB에서 실수 방지
- **큐레이션 적합성:** SQLite 전용은 아니나 안정적이고 쾌적한 범용 DB 클라이언트. 무료 티어의 제한이 큐레이션 워크플로우에 불편할 수 있음

#### litecli — 향상된 SQLite CLI

[dbcli.com/litecli](https://dbcli.com/litecli). Python 기반, BSD-3.

- **현황:** v1.17.1 (2026), dbcli 패밀리 (pgcli, mycli와 동일 계열)
- **자동완성:** 테이블명, 컬럼명, 앨리어스를 컨텍스트 인식으로 자동완성. 퍼지 매칭 (`djmi` → `django_migrations`)
- **출력 포맷:** 15개+ 포맷 (fancy_grid, github/Markdown, csv, html 등). `\T csv`로 즉시 전환
- **sqlite3 CLI 대비:** 구문 하이라이팅, 다중 행 쿼리, 설정 파일(`.liteclirc`), Emacs/Vi 키바인딩
- **큐레이션 적합성:** raw `sqlite3`의 상위 호환. 빠른 일회성 쿼리에 최적이나 편집 UI 없음

### 사용 시나리오별 권장

| 시나리오 | 권장 도구 |
|---|---|
| 단일 큐레이터, macOS | **Base** 또는 **sqlit** |
| 단일 큐레이터, 크로스플랫폼 | **SQLiteStudio** |
| 팀 큐레이션 (다수 참여) | **datasette** + write-ui 플러그인 |
| 빠른 일회성 확인 (터미널) | **litecli** |
| 커스텀 큐레이션 로직 필요 | **SQLiteStudio** (커스텀 SQL 함수) |

---

> **최종 검토일:** 2026-03-06 | **정합 대상:** design-philosophy.md, design-implementation.md, README.md
