# Decision: PR body 템플릿은 스코프 밖

**Decision**: PR body 템플릿이나 포맷 규격을 knowledge-distillery에서 제공하지 않는다.

**Context**: PR description이 파이프라인의 evidence로 활용되고 있어 템플릿 보강 여부를 검토했다. 현재 extract-candidates가 LLM 기반으로 자유 형식 PR body에서도 signal을 추출하고 있어 정형화된 섹션이 필수가 아님을 확인했다.

**Rationale**: 프로젝트마다 PR body 컨벤션이 다르므로, distillery가 특정 포맷을 강제하는 것은 적절하지 않다. 추출 정확도 향상이 필요하면 파이프라인 쪽 프롬프트를 개선하는 방향으로 해결한다.
