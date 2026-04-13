# Decision: 코드 표현 필터링 강화에 접근 B 선택

**Decision**: 코드에 이미 표현된 내용의 필터링 강화를 위해 접근 B(프롬프트 강화 + quality-gate R7 파일 검증 승격)를 적용한다.

**Context**: refine 파이프라인에서 Q2 strictness 강화(PR #31) 이후에도 "how-it-works" 유형의 후보가 계속 추출되는 문제가 있었다. 코드 구조, 주석, 설정 파일, directive 문서 등에 이미 표현된 구현 메커니즘을 기술하는 entity가 vault에 추가되는 경향이 강했다. 두 가지 접근을 검토했다.

**Rationale**: 접근 A(구조화된 `_derivability_audit` 필드를 후보마다 필수로 요구)는 "읽은 파일 → 코드가 표현하는 것 → 코드에 없는 것"을 명시적으로 작성하게 하여 구조적으로 false positive를 차단할 수 있다. 그러나 현재 PoC 단계에서는 토큰 소비 증가와 파이프라인 복잡도가 과도하다. 접근 B는 기존 구조를 유지하면서 extract-candidates의 Q1 판단 기준 명시화, "how-it-works" 거부 패턴 추가, quality-gate R7의 파일 읽기 권한 부여로 충분한 효과를 볼 수 있다.

**Alternatives considered**:
- **접근 A — 구조화된 derivability audit**: 각 후보에 `_derivability_audit` 필드를 필수로 요구하여 읽은 파일, 코드가 표현하는 것, 코드에 없는 것을 명시적으로 기록. 구조적으로 더 강력하지만 PoC 단계에서 과도한 복잡도와 토큰 소비. 장기적으로 접근 B가 부족하다고 판명되면 전환 검토.
