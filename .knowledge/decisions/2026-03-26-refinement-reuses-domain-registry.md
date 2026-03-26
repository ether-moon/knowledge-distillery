# Decision: 정제 단계는 전체 도메인 레지스트리를 재사용한다

**Decision**: 정제 단계의 도메인 배정은 전체 active domain registry를 controlled vocabulary로 먼저 조회해 기존 도메인을 우선 재사용하고, clean fit이 없을 때만 새 도메인을 제안한다.

**Context**: Context Gate에서 도메인 ID를 경량 인덱스로 활용하는 방향을 정리한 뒤, refinement 단계 역시 전체 도메인 이름을 알고 재사용 가능한 것은 재사용하고 merge/split/rename/scope cleanup이 필요한 경우를 후속 개선 신호로 다루는 편이 더 적합하다는 논의가 이어졌다. 새 도메인을 매번 로컬 배치 관점에서만 만들면 registry churn과 near-duplicate naming이 쉽게 발생한다.

**Rationale**: domain registry는 단순 저장소가 아니라 controlled vocabulary이므로, refinement LLM도 이를 전체적인 분류 기준으로 사용해야 한다. 기존 도메인이 완벽하지 않더라도 현재 배치의 가장 가까운 fit이라면 우선 재사용하고, 품질 문제는 batch report와 후속 domain maintenance에서 merge/split/rename 후보로 다루는 편이 안정적이다. 이렇게 해야 naming drift를 줄이고, 도메인 체계가 배치마다 흔들리지 않으면서도 점진적으로 더 좋아질 수 있다.
