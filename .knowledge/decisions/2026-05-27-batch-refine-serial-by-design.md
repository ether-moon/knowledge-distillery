# Decision: batch-refine은 의도적으로 serial 처리

**Decision**: batch-refine은 PR을 순차적으로 처리한다. 처리량 개선이 필요할 때 PR 단위 병렬화(GitHub Actions matrix 등 단순 fan-out)는 채택하지 않는다.

**Context**: 한 달에 100+ PR이 생성되는 레포에 knowledge-distillery를 적용한 결과 주간 batch-refine으로 큐의 10%도 처리하지 못하는 처리량 문제가 발견되었다. 즉각적인 throughput 개선책으로 PR 단위 matrix 병렬화가 제안되었으나, 현 파이프라인의 atomic 보장과 충돌함이 확인되었다.

**Rationale**: serial 처리는 두 가지 보장을 위해 의도된 설계다. (1) GitHub token 만료 전 graceful handoff — PR 경계에서만 안전하게 중단/재개 가능. (2) PR 단위 atomic commit/label 업데이트 — `knowledge:pending → knowledge:collected` 라벨 전이와 `.knowledge/changesets/` / report PR 갱신이 PR 하나의 처리 단위 안에서 함께 commit된다. 단순 matrix 병렬화는 (a) 동일 changeset/report 파일에 대한 동시 쓰기 충돌, (b) 라벨 전이 race condition, (c) self-retrigger와 결합 시 동일 PR 중복 처리를 일으킨다. 처리량 개선은 다른 레버(사전 필터링, 일별 mini-batch)를 먼저 시도한다.

**Alternatives considered**:
- **PR 단위 matrix 병렬화**: throughput은 즉시 N배 개선되나 changeset/report 동시 쓰기 충돌, 라벨 race, 중복 처리 발생. atomic 보장이 깨져 데이터 정합성 문제로 직결된다.
- **shard별 branch/artifact + 마지막 aggregation job**: 병렬화 자체는 가능하나 파이프라인 재설계 비용이 크다. 현 시점에서는 사전 필터링과 mini-batch 전환의 합으로 동일한 throughput 개선을 더 낮은 위험으로 달성할 수 있다고 판단.
