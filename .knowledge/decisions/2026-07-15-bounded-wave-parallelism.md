# Decision: batch-refine bounded wave 병렬화

**Decision**: batch-refine은 최대 K=3개의 PR 분석을 bounded wave로 병렬 실행하되, changeset/report persist·commit·push·label 전이는 오케스트레이터 sole writer가 `mergedAt` 순으로 직렬 수행한다.

**Context**: 2026-05-27 결정은 단순 PR matrix 병렬화가 동시 파일 쓰기, label race, self-retrigger 중복 처리를 일으키므로 serial 처리를 채택했다. 이후 중복 검증 제거와 daily mini-batch를 적용해도 PR별 분석 시간이 누적되는 직렬 wall-clock이 주요 병목으로 남았다. 분석은 read-only subagent에 격리할 수 있지만, durable state 변경은 기존 원자성 경계를 유지해야 한다.

**Rationale**: 한 wave에서 최대 3개의 fresh subagent가 collect-evidence → extract-candidates → quality-gate를 각각 순차 실행하면 분석 wall-clock을 줄이면서 동시 writer 문제를 피할 수 있다. 모든 결과가 settle하고 auth-dead 결과가 없음을 확인한 뒤에만 오케스트레이터가 `mergedAt` 순으로 PR별 checkpoint를 직렬 persist하므로 changeset/report와 label 전이의 순서를 보존한다. 대가로 runner timeout이나 hang 시 serial의 1개가 아니라 최대 한 wave(K개)를 다시 분석할 수 있으며, 잠정 15분 마진은 첫 실전 wave telemetry로 재검증한다.

**Alternatives considered**:
- **Serial 유지**: 가장 단순하고 재작업 단위가 1개지만, PR별 분석 시간이 합산되어 현재 처리량 병목을 해소하지 못한다.
- **단순/unbounded GitHub Actions matrix fan-out**: 동일 changeset/report의 동시 쓰기, label race, self-retrigger 중복 처리 위험 때문에 계속 기각한다.
- **Shard별 branch/artifact + final aggregation**: writer 충돌은 피할 수 있지만 별도 aggregation 상태 머신과 복구 경로가 필요해 현재 PoC 단계에는 복잡도가 과도하다.

**Supersedes**: `2026-05-27-batch-refine-serial-by-design`
