# Decision: Portable skill-local packaging

**Decision**: Knowledge Distillery 배포 자산을 소유 스킬 디렉터리 안에 배치하고, 에이전트 훅은 setup 스킬이 호스트별 저장소 설정에 설치한다.

**Context**: 기존 구조는 CLI, schema, hooks를 Claude Code 플러그인 루트에 두고 `CLAUDE_PLUGIN_ROOT`로 찾았다. `npx skills`로 Codex에 설치하면 각 스킬 디렉터리만 로드되므로 이 경로와 자동 훅 등록이 성립하지 않았다.

**Rationale**: 실행 파일과 초기화 자산을 사용하는 스킬 안에 함께 두면 복사와 symlink 설치 모두 같은 상대 경로로 동작한다. setup이 `.codex/hooks.json` 또는 `.claude/settings.json`과 repo-local 훅 스크립트를 설치하면 portable skill 설치가 지원하지 않는 훅 등록을 명시적으로 복구할 수 있다. vault 알림은 훅이 제공한 정확한 CLI 경로를 우선 사용하고, Codex 전역 설치에서는 `CODEX_HOME`을 fallback으로 사용한다.

**Alternatives considered**:
- **Claude Code 플러그인 루트 구조 유지**: Claude Code에서는 단순하지만 `npx skills`로 설치된 Codex 세션에 플러그인 루트 환경 변수와 번들 경로가 없어 제외했다.
- **에이전트별 CLI 설치를 별도로 요구**: 스킬과 실행 파일의 버전이 분리되고 setup 재현성이 낮아져 제외했다.
