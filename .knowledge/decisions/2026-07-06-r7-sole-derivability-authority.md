# Decision: 아티팩트 기반 파생가능성 검증의 권위를 R7로 단일화

**Decision**: 파일을 읽어 수행하는 권위적 Q1/Q2 파생가능성 검증은 quality-gate R7(effort:high)에서만 수행한다. extract-candidates 4d는 파일을 읽지 않는 값싼 텍스트 휴리스틱 프리필터로 강등하며, 명백한 how-it-works 형태만 걸러내고 애매하면 후보를 유지한다. 마찬가지로 중복 판정(4b↔R6)도 R6를 유일 권위자로 두고 4b는 힌트만 세팅한다.

**Context**: refine 파이프라인 감사(2026-07-06) 결과, 후보당 가장 비싼 작업인 "repo 파일 read + Q1/Q2 파생가능성 판정"이 두 번 수행됨을 확인했다 — 먼저 extract-candidates 4d(세션 티어 Sonnet/medium)에서, 다시 quality-gate R7(effort:high)에서. R7은 이미 4d의 자기서술을 신뢰하지 않고 아티팩트를 처음부터 다시 읽어 판정하도록 설계되어 있어(2026-04-13 `code-expressed-filtering-approach-b` 결정으로 R7에 파일 읽기 권한이 부여됨), 4d의 필수 파일 읽기는 최종 정밀도에 기여하지 않는 중복 작업이다. batch-refine이 직렬(2026-05-27 `batch-refine-serial-by-design`)이라 이 중복은 후보·PR 수에 정확히 비례해 누적된다.

**Rationale**: 정밀도(잘못된 지식의 vault 유입 차단, "costly, hard-to-detect failure")의 보증은 R7(effort:high, 경계 시 reject 편향)에 있다. 4d의 파일 읽기를 제거해도 R7이 모든 Layer 1 생존 후보를 아티팩트로 다시 검증하므로 정밀도 보증은 그대로 유지된다. 4d는 명백한 how-it-works 후보만 값싸게 걸러내고 애매하면 유지하므로, 유일한 리스크는 프리필터가 잘못 버린 후보의 false-negative인데 이는 `conservative-extraction-principle`("애매하면 제외, 놓친 지식은 다음 사이클에 재추출 가능")이 허용하는 방향이다. how-it-works 거부 패턴과 Q2 strictness(self-evident rationale은 residual value가 아님, 2026-03-30 결정)는 4d(휴리스틱)와 R7(권위) 양쪽에 그대로 보존한다. 이 결정은 vault entry `derivability-two-question-test`(PR #23)의 "Q1/Q2 아티팩트 테스트는 4d에서 수행하고 R7은 아티팩트를 검사할 수 없는 보조 휴리스틱"이라는 배치 주장을 갱신한다 — 해당 엔트리의 considerations는 2026-04-13 접근 B(R7 파일 읽기 승격) 이후 이미 outdated 상태이며, 그 엔트리 자신의 Stop Condition("false positive가 지속되면 quality-gate에 아티팩트 검사 기능을 추가해 재검토")이 예고한 진화를 완성하는 것이다. 또한 2026-04-13 접근 B를 refine한다: R7을 보조 안전망이 아니라 파생가능성의 유일 권위 검증자로 재정의한다.

**Alternatives considered**:
- **현상 유지 (4d·R7 이중 파일 검증)**: 정밀도는 동일하나 후보당 가장 비싼 작업(파일 read + 판정)을 두 티어에서 중복 수행. 직렬 드레인에서 누적 비용이 후보 수에 비례해 커져 기각.
- **R7 제거, 4d를 유일 검증자로**: 4d는 세션 티어(Sonnet/medium)이며 reject 편향 규율이 없어 false positive가 증가할 위험 — 접근 B가 막으려던 바로 그 실패 유형이라 기각. 권위는 반드시 effort:high 게이트에 두어야 한다.
