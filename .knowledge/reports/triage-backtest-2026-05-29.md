# Triage Backtest - 2026-05-29

## 요약
- 총 평가 PR: 10
- skip 판정 (positive-recall regression): 1 / 10 = 10.00%
- threshold: <= 5%
- PR 조회 실패: 0
- Layer 2 fallback: 0
- baseline validity: usable

## Layer 1 skip breakdown

## Layer 2 decision breakdown
- skip: 1
- extract: 9

## Layer 2 reason breakdown
- extract / 플러그인 스킬 메타데이터 및 안전성 수정(.env 스테이징 방지, --only 사용)이 포함된 결정/정책 변경: 1
- extract / Contains decision records (ADR-style files in .knowledge/decisions/) and meaningful CLI/skill changes with memento evidence.: 1
- extract / 버그 픽스와 함께 memento-commit 워크플로우 사용을 의무화하는 결정 파일이 포함되어 있어 추출 가치가 있음: 1
- extract / Docs changes encode policy decisions (new R7 rule, criterion 4d replacement, fact-type narrowing) with explicit rationale and design tradeoffs.: 1
- extract / 신규 skill 추가 + AGENTS.md에 Decision Recording 섹션(정책/규칙 신호) + decisions/ 경로의 결정 기록 포함: 1
- extract / 코드 + 워크플로 + 스킬 신규 추가로 큐레이션 기능 도입 결정과 컨벤션 신호가 명확하다.: 1
- extract / 파일 수준 패턴 허용 결정과 검증 로직 변경이 함께 포함되어 있고 decision 파일과 memento 신호가 존재함: 1
- skip / Test-only PR adding regression harnesses with no decision signals and no manifest signals (no linear/slack/notion/greptile): 1
- extract / AGENTS.md/CLAUDE.md 디렉티브 이전과 memento 워크플로우 정책을 신설하는 결정 신호가 명확함.: 1
- extract / Architectural change replacing binary vault.db commits with text changeset flow — clear convention/policy signals in workflow design: 1

_상세는 /Users/ether/conductor/workspaces/knowledge-distillery/kelowna/.knowledge/reports/triage-backtest-2026-05-29.json 참고._
