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

## 1. 에이전트에게 Skill 설치 요청

Root README를 통하거나 직접 URL로 [Agent Installation Guide](../agent-installation.md)를 코딩 에이전트에게 전달한다. 이 문서가 project-scope skill 선택, 저장소 구성, 보존 규칙, 검증의 source of truth다.

설치기는 적용 대상 저장소에 런타임 skill 네 개만 유지한다. 파이프라인 전용 skill 여섯 개는 관리되는 workflow가 자체 plugin checkout에서 로드한다.

## 2. 설치 에이전트가 저장소 구성

같은 에이전트가 설치 문서 절차를 계속 수행하며 호출할 setup skill은 없다. 다음을 구성한다.

- `.knowledge/vault.db`
- `.knowledge/reports/`
- `.knowledge/changesets/`
- `.knowledge/decisions/`
- `.github/workflows/mark-evidence.yml`
- `.github/workflows/batch-refine.yml`
- `.github/workflows/curate-report.yml`
- `.github/workflows/apply-changeset.yml`
- `AGENTS.md` 또는 `CLAUDE.md`의 Knowledge Vault, Memento, Decision Recording 섹션
- `.gitignore`의 임시 파일 규칙
- 현재 에이전트용 repo-local hook과 hook 설정

에이전트는 `plugins/knowledge-distillery/install/`에서 정식 asset을 가져오고, 무관한 기존 설정을 보존하며, 최종 상태를 검증해 보고한다. 설치 문서의 모든 검증 항목이 통과해야 완료된 것으로 본다.

Codex에서는 저장소를 trust한 뒤 `/hooks`에서 새 hook 또는 변경된 hook을 검토한다. Portable skill installer는 skill만 복사하므로, lifecycle hook 등록은 설치 문서 절차가 호스트별로 수행한다.

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

- 설치 에이전트가 설치 문서의 모든 검증 항목을 통과했다고 보고한다
- 대표 경로 하나에 대해 `knowledge-gate query-paths <file>`가 의미 있는 결과를 반환한다
- GitHub Actions가 필요한 secret에 접근할 수 있다
- 생성된 workflow가 저장소의 branch/schedule 정책과 맞는다
