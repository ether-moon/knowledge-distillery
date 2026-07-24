# 도입 가이드

Knowledge Distillery를 적용하려는 저장소에서 이 가이드를 따른다.

## 사전 조건

- 다음 설치 경로 중 하나:
  - Claude Code plugin 설치 권한
  - Codex portable skill 설치용 Node.js와 `npx`
- 머신에 `sqlite3` 설치
- 파이프라인/관리 커맨드까지 사용할 경우 `jq` 설치
- 저장소 secret 준비:
  - `ANTHROPIC_API_KEY`
  - Linear를 쓰는 경우 `LINEAR_API_KEY`

## 1. Skill 설치

설치 환경에 맞는 경로를 선택한다.

Claude Code에서는 이 저장소의 plugin을 설치한다. 설치된 skill은 `/knowledge-distillery:*` namespace로 노출된다.

Codex에서는 portable skill 디렉터리를 설치한다.

```bash
npx skills add https://github.com/ether-moon/knowledge-distillery/tree/main/plugins/knowledge-distillery --skill '*' -a codex
```

Codex의 project skill은 기본적으로 `.agents/skills/`에, global skill은 `$CODEX_HOME/skills/`에 설치된다. 각 skill이 필요한 script와 asset을 직접 포함하므로 `CLAUDE_PLUGIN_ROOT`가 필요하지 않다.

## 2. 저장소 설정

적용 대상 저장소에서 setup skill을 호출한다.

```text
Claude Code plugin: /knowledge-distillery:setup
Codex skill install: $setup
```

이 단계에서 다음이 설정된다.

- `.knowledge/vault.db`
- `.knowledge/reports/`
- `.knowledge/changesets/`
- `.github/workflows/mark-evidence.yml`
- `.github/workflows/batch-refine.yml`
- `.github/workflows/curate-report.yml`
- `.github/workflows/apply-changeset.yml`
- `AGENTS.md` 또는 `CLAUDE.md`의 Knowledge Vault와 Memento 섹션
- `.gitignore`의 임시 파일 규칙
- 현재 에이전트용 repo-local hook과 hook 설정

Skill은 설정을 마지막에 자체 검증하고 결과를 보고한다.
모든 검증 항목이 통과해야 설정이 완료된 것으로 본다.

Codex에서는 저장소를 trust한 뒤 `/hooks`에서 새 hook 또는 변경된 hook을 검토한다. Portable skill installer는 skill만 복사하므로, lifecycle hook 등록은 setup이 호스트별로 수행한다.

## 3. 저장소 설정 조정

다음을 저장소에 맞게 검토하고 조정한다.

- workflow target branch
- workflow schedule
- Linear 연동 사용 여부
- vault의 초기 domain과 seed entry

## 4. 초기 지식 시드 추가

첫날부터 런타임 경로가 비지 않도록 전역 규칙 또는 횡단 관심사 규칙을 최소 1개 이상 넣는다.

예시:

```bash
knowledge-gate domain-add global-conventions "Project-wide rules"
knowledge-gate domain-paths-add global-conventions "*"
knowledge-gate add \
  --type fact \
  --title "Keep Controllers Thin" \
  --claim "Keep controllers thin and push orchestration into dedicated services" \
  --body "## Background\nThis project keeps orchestration out of controllers.\n\n## Details\nMove multi-step flows into service objects." \
  --domain global-conventions \
  --considerations "Applies to request-handling entry points." \
  --evidence "pr:#1"
```

## 5. 운영 모델

도입 후 기본 운영 원칙은 다음과 같다.

- 에이전트는 `knowledge-gate`를 통해 vault를 조회한다
- 원시 evidence는 vault 밖에 둔다
- 커버되지 않은 영역의 구조적 변경은 여전히 사람 확인이 필요하다
- 배치 정제는 검증된 Fact / Anti-Pattern만 승격한다

## 6. 첫 운영 확인

본격 사용 전 다음만 확인하면 된다.

- setup skill이 모든 검증 항목을 통과했다고 보고한다
- 대표 경로 하나에 대해 `knowledge-gate query-paths <file>`가 의미 있는 결과를 반환한다
- GitHub Actions가 필요한 secret에 접근할 수 있다
- 생성된 workflow가 저장소의 branch/schedule 정책과 맞는다
