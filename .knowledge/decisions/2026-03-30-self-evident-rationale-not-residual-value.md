# Decision: Self-evident rationale does not count as Q2 residual value

**Decision**: Q2 derivability 판정에서 self-evident rationale은 residual value로 인정하지 않는다. "왜"가 코드 패턴 자체에서 추론 가능한 경우 (input validation → injection 방지, fail-fast → silent failure 방지 등) Q2=no로 판정한다.

**Context**: PR #30 batch에서 8개 entry가 모두 accepted되었으나, 대부분 코드에 이미 구현된 동작을 설명하는 것이었다. Q2 테스트를 통과한 이유는 body에 rationale 텍스트가 있었기 때문이지만, 해당 rationale은 엔지니어링 패턴에서 자명하게 도출 가능한 내용이었다. 이전 batch (2026-03-26)에서도 R7 rejection이 있었으나 기준이 충분히 엄격하지 않아 재발했다.

**Rationale**: Vault에 저장할 지식은 코드를 읽는 개발자가 재구성할 수 없는 정보여야 한다. Pattern-inherent rationale (패턴 자체에 내재된 이유), standard engineering practice (표준 엔지니어링 관행), 코드의 에러 메시지나 변수명에서 이미 드러나는 의도는 residual value가 아니다. Q2=yes가 되려면 과거 인시던트, 비자명한 트레이드오프, 코드베이스 외부의 정책 제약, 또는 직관에 반하는 경계 조건처럼 genuinely non-obvious한 맥락이 있어야 한다.
