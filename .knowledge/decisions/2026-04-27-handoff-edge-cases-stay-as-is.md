# Decision: batch-refine 핸드오프 엣지케이스는 현 상태 유지

**Decision**: batch-refine graceful 핸드오프 디자인에서 피어 LLM 리뷰가 짚은 세 가지 엣지케이스(단일 PR stall로 데드라인 초과, push 성공 후 라벨 flip 실패 시 changeset 중복, 첫 PR이 401로 죽으면 Report PR 미존재로 가시성 0)에 대해 별도 안전장치를 추가하지 않고 현 상태로 유지한다.

**Context**: GitHub 토큰 만료 전 graceful 핸드오프 + 자기 재트리거 메커니즘을 구현한 후, gemini/codex/claude 피어 리뷰에서 위 세 가지 엣지케이스가 남아 있다는 지적이 나왔다. 각 케이스마다 추가 디자인이 필요한지 사용자와 검토했다.

**Rationale**: 세 케이스 모두 silent하지 않으며 다음 사이클에서 자연 회복된다 — (1) 단일 PR stall은 60분 job timeout이 안전망이고 다음 cron이 미처리 PR을 가져감, (2) 라벨 flip 실패 후 changeset 중복은 Report PR 사람 검토 단계에서 `/curate`로 처리 가능, (3) 첫 PR 실패 시 Report PR 미존재는 GitHub Actions 실행 로그가 흔적을 남기고 다음 cron이 재시도. 추가 안전장치(mid-PR 체크포인트, changeset 기반 source-of-truth, 빈 Report PR 사전 생성)의 복잡도가 얻는 가치를 능가하지 않는다. AGENTS.md의 "tight constraints and exhaustive safeguards make future iteration harder" 철학에 따라 현 단계에서는 단순함을 유지한다.

**Alternatives considered**:
- **PR 처리 중 mid-step 시간 체크포인트**: 각 sub-skill 호출 사이에 데드라인 검사 추가. 거부 — claude-code-action / Agent tool 레벨 타임아웃 적용 가능 여부가 불확실하고, stall이 충분히 드물어 메커니즘 도입을 정당화하지 못함.
- **changeset에 `_source_pr_processed` 메타로 진실 원천 이전**: 라벨 대신 changeset 자체로 멱등성 보장. 매력적이지만 별도 디자인 작업으로 분리. 중복이 실제 신호가 되면 그때 다시 검토.
- **discover step에서 빈 Report PR 사전 생성**: 첫 PR 실패 가시성 확보. 거부 — GitHub Actions 로그로 흔적이 충분하고, 빈 PR은 노이즈만 증가.
