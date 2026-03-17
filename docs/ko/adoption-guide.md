# 도입 가이드

Knowledge Distillery를 적용하려는 저장소에서 이 가이드를 따른다.

## 사전 조건

- Claude Code plugin 설치 권한
- 머신에 `sqlite3` 설치
- 파이프라인/관리 커맨드까지 사용할 경우 `jq` 설치
- 저장소 secret 준비:
  - `ANTHROPIC_API_KEY`
  - Linear를 쓰는 경우 `LINEAR_API_KEY`

## 1. Plugin 설치

이 저장소의 Claude Code plugin을 설치한다.

기대 결과:

- Claude Code가 `/knowledge-distillery:*` skill을 인식한다
- 번들 자산이 `${CLAUDE_PLUGIN_ROOT}`를 통해 접근 가능하다

## 2. 저장소 초기화

적용 대상 저장소에서 다음을 실행한다.

```text
/knowledge-distillery:init
```

이 단계에서 다음이 설정된다.

- `.knowledge/vault.db`
- `.knowledge/reports/`
- `.github/workflows/mark-evidence.yml`
- `.github/workflows/batch-refine.yml`
- `CLAUDE.md`의 Knowledge Vault 섹션
- `.gitignore`의 `.knowledge/tmp/` 항목

초기화 마지막에는 다음 self-check를 실행해야 한다.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/knowledge-gate doctor
```

이 점검이 통과해야만 초기화가 완료된 것으로 본다.

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

- 저장소 루트에서 `knowledge-gate doctor`가 통과한다
- 대표 경로 하나에 대해 `knowledge-gate query-paths <file>`가 의미 있는 결과를 반환한다
- GitHub Actions가 필요한 secret에 접근할 수 있다
- 생성된 workflow가 저장소의 branch/schedule 정책과 맞는다
