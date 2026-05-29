#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi
GATE="${SCRIPT_DIR}/knowledge-gate"

MODE="full"
LIMIT=50
while [ $# -gt 0 ]; do
  case "$1" in
    --layer1-only) MODE="layer1-only"; shift ;;
    --layer2-only) MODE="layer2-only"; shift ;;
    --limit) LIMIT="${2:-50}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--layer1-only|--layer2-only] [--limit N]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required tool not found: $1" >&2
    exit 3
  }
}

require_tool jq

path_basename() {
  local path="$1"
  echo "${path##*/}"
}

is_lockfile() {
  local path="$1"
  local base
  base="$(path_basename "$path")"
  case "$base" in
    *-lock.json|*.lock|Gemfile.lock|Cargo.lock|package-lock.json|yarn.lock|pnpm-lock.yaml|poetry.lock|uv.lock|composer.lock|mix.lock|go.sum)
      return 0
      ;;
    *) return 1 ;;
  esac
}

is_generated() {
  local path="$1"
  local base
  base="$(path_basename "$path")"
  case "$path" in
    generated/*|*/generated/*|__generated__/*|*/__generated__/*|dist/*|*/dist/*|build/*|*/build/*|__snapshots__/*|*/__snapshots__/*)
      return 0
      ;;
  esac
  case "$base" in
    *.snap) return 0 ;;
    *) return 1 ;;
  esac
}

is_dependency_metadata() {
  local path="$1"
  local base
  base="$(path_basename "$path")"
  case "$base" in
    package.json|pyproject.toml|requirements*.txt|Gemfile|go.mod|Cargo.toml|composer.json|mix.exs)
      return 0
      ;;
    *) return 1 ;;
  esac
}

json_files() {
  jq -r '.files[]? | if type == "string" then . else .path end'
}

all_files_match() {
  local pr_json="$1"
  local matcher="$2"
  local count=0
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    count=$((count + 1))
    "$matcher" "$file" || return 1
  done <<EOF
$(echo "$pr_json" | json_files)
EOF
  [ "$count" -gt 0 ]
}

all_files_dep_related() {
  local pr_json="$1"
  local count=0
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    count=$((count + 1))
    is_dependency_metadata "$file" || is_lockfile "$file" || is_generated "$file" || return 1
  done <<EOF
$(echo "$pr_json" | json_files)
EOF
  [ "$count" -gt 0 ]
}

layer1_eval() {
  local pr_json="$1"
  local author_is_bot title title_lower body
  author_is_bot="$(echo "$pr_json" | jq -r '.author.is_bot // false')"
  title="$(echo "$pr_json" | jq -r '.title // ""')"
  title_lower="$(echo "$title" | tr '[:upper:]' '[:lower:]')"
  body="$(echo "$pr_json" | jq -r '.body // ""')"

  # Rule order mirrors mark-evidence/SKILL.md (first match wins):
  # R1 bot-dependency-update → R2 lockfile-only → R3 generated-only → R4 auto-revert.
  if [ "$author_is_bot" = "true" ] && [[ "$title_lower" =~ dependabot|renovate|bump|update\ dependenc|upgrade\ dependenc ]]; then
    if all_files_dep_related "$pr_json"; then
      echo '{"decision":"skip","rule":"bot-dependency-update"}'
      return
    fi
  fi

  if all_files_match "$pr_json" is_lockfile; then
    echo '{"decision":"skip","rule":"lockfile-only"}'
    return
  fi

  if all_files_match "$pr_json" is_generated; then
    echo '{"decision":"skip","rule":"generated-only"}'
    return
  fi

  if [[ "$title" == Revert\ \"* ]] && { [ -z "$body" ] || [[ "$body" =~ ^This\ reverts\ commit\ [a-f0-9]+\.$ ]]; }; then
    echo '{"decision":"skip","rule":"auto-revert"}'
    return
  fi

  echo '{"decision":"pass"}'
}

layer2_eval() {
  require_tool claude
  local pr_json="$1"
  local prompt response json err_file status first_err
  prompt=$(cat <<EOF
당신은 PR triage 분류기입니다. 다음 PR이 knowledge-distillery 파이프라인에서 처리할 가치가 있는지 판단합니다.

[PR 데이터]
$(echo "$pr_json" | jq .)

[판정 가이드]
- 보수 편향: 확실히 낮은 가치일 때만 "skip". 애매하면 "extract" 또는 "defer".
- "skip" 대상: docs-only + 결정 신호 없음, test-only + manifest 신호 부재, i18n only.
  - 결정 키워드: decide, decision, convention, policy, ADR, deprecate, adopt, must, must not, 결정, 정책, 규칙, 채택, 금지, 폐기, 합의
  - 결정 경로: docs/adr/, docs/decisions/, CONTEXT.md, RFC*
- "defer": 큰 PR + manifest 신호 빈약, 혼합 변경 등 신뢰 못 할 때.
- "extract": 기본값.

[출력] JSON 한 줄. 주석 금지:
{"decision":"skip|extract|defer","reason":"<한 문장>","signals":["<bullet>"]}
EOF
)
  err_file="$(mktemp)"
  status=0
  response=$(echo "$prompt" | claude --print 2>"$err_file") || status=$?
  if [ "$status" -ne 0 ]; then
    first_err="$(head -1 "$err_file" | tr -d '\r')"
    rm -f "$err_file"
    jq -cn --arg note "$first_err" '{decision:"extract",reason:"claude-call-fallback",signals:[$note]}'
    return
  fi
  rm -f "$err_file"
  json=$(echo "$response" | grep -oE '\{[^}]*"decision"[^}]*\}' | tail -1 || true)
  if [ -z "$json" ] || ! echo "$json" | jq . >/dev/null 2>&1; then
    echo '{"decision":"extract","reason":"parse-fallback","signals":[]}'
    return
  fi
  case "$(echo "$json" | jq -r '.decision // ""')" in
    skip|extract|defer) echo "$json" ;;
    *) echo '{"decision":"extract","reason":"schema-fallback","signals":[]}' ;;
  esac
}

if [ "$MODE" = "layer1-only" ]; then
  layer1_eval "$(cat)"
  exit 0
fi

if [ "$MODE" = "layer2-only" ]; then
  layer2_eval "$(cat)"
  exit 0
fi

require_tool gh
require_tool claude

DATE="$(date +%Y-%m-%d)"
REPORT_DIR="${ROOT}/.knowledge/reports"
REPORT_MD="${REPORT_DIR}/triage-backtest-${DATE}.md"
REPORT_JSON="${REPORT_DIR}/triage-backtest-${DATE}.json"
mkdir -p "$REPORT_DIR"

PR_NUMBERS="$("$GATE" recent-accepted-prs --limit "$LIMIT")"
TOTAL=0
SKIPPED=0
LOOKUP_FAILED=0
CLAUDE_FALLBACK=0
TMP_JSON="${REPORT_JSON}.tmp"
TMP_COUNTS="$(mktemp)"
trap 'rm -f "$TMP_COUNTS" "$TMP_JSON"' EXIT

echo "[" > "$TMP_JSON"
FIRST=true

for pr_num in $PR_NUMBERS; do
  pr_meta="$(gh pr view "$pr_num" --json author,title,body,files,labels,comments 2>/dev/null || true)"
  if [ -z "$pr_meta" ]; then
    LOOKUP_FAILED=$((LOOKUP_FAILED + 1))
    continue
  fi
  TOTAL=$((TOTAL + 1))

  manifest_json="$(echo "$pr_meta" | jq -r '[.comments[]?.body // "" | select(contains("<!-- EVIDENCE_BUNDLE_MANIFEST_START -->"))] | last // ""' | sed -n '/```json/,/```/p' | sed '1d;$d' || true)"
  if [ -n "$manifest_json" ] && echo "$manifest_json" | jq . >/dev/null 2>&1; then
    manifest_summary="$(echo "$manifest_json" | jq '{linear:(.identifiers.linear|length), slack:(.identifiers.slack|length), memento:((.identifiers.memento|length)>0), greptile_comments:([.identifiers.greptile[]?.comment_count] | add // 0), notion:(.identifiers.notion|length)}')"
  else
    manifest_summary='{"linear":0,"slack":0,"memento":false,"greptile_comments":0,"notion":0}'
  fi

  l1_input="$(echo "$pr_meta" | jq '{author:.author,title:.title,body:.body,files:[.files[] | .path]}')"
  l1="$(layer1_eval "$l1_input")"
  if [ "$(echo "$l1" | jq -r '.decision')" = "skip" ]; then
    SKIPPED=$((SKIPPED + 1))
    rule="$(echo "$l1" | jq -r '.rule')"
    echo "L1|$rule" >> "$TMP_COUNTS"
    entry="$(jq -c -n --arg pr "$pr_num" --argjson result "$l1" '{pr:$pr, layer:"L1", result:$result}')"
  else
    l2_input="$(echo "$pr_meta" | jq --argjson ms "$manifest_summary" '{author:.author,title:.title,body:.body,labels:[.labels[]?.name],files:[.files[] | {path:.path, additions:.additions, deletions:.deletions}],manifest_summary:$ms}')"
    l2="$(layer2_eval "$l2_input")"
    decision="$(echo "$l2" | jq -r '.decision')"
    reason="$(echo "$l2" | jq -r '.reason // "unknown"')"
    [ "$decision" = "skip" ] && SKIPPED=$((SKIPPED + 1))
    case "$reason" in
      claude-call-fallback|parse-fallback|schema-fallback) CLAUDE_FALLBACK=$((CLAUDE_FALLBACK + 1)) ;;
    esac
    echo "L2|$decision|$reason" >> "$TMP_COUNTS"
    entry="$(jq -c -n --arg pr "$pr_num" --argjson result "$l2" '{pr:$pr, layer:"L2", result:$result}')"
  fi

  if [ "$FIRST" = "true" ]; then
    FIRST=false
  else
    echo "," >> "$TMP_JSON"
  fi
  echo "$entry" >> "$TMP_JSON"
done

echo "]" >> "$TMP_JSON"
mv "$TMP_JSON" "$REPORT_JSON"

if [ "$TOTAL" -gt 0 ]; then
  PCT="$(awk -v s="$SKIPPED" -v t="$TOTAL" 'BEGIN { printf "%.2f", (s/t)*100 }')"
else
  PCT="N/A"
fi

{
  echo "# Triage Backtest - ${DATE}"
  echo
  echo "## 요약"
  echo "- 총 평가 PR: ${TOTAL}"
  echo "- skip 판정 (positive-recall regression): ${SKIPPED} / ${TOTAL} = ${PCT}%"
  echo "- threshold: <= 5%"
  echo "- PR 조회 실패: ${LOOKUP_FAILED}"
  echo "- Layer 2 fallback: ${CLAUDE_FALLBACK}"
  if [ "$CLAUDE_FALLBACK" -gt 0 ] || [ "$LOOKUP_FAILED" -gt 0 ]; then
    echo "- baseline validity: degraded (fallback/lookup 발생 — 유효 baseline 아님)"
  else
    echo "- baseline validity: usable"
  fi
  echo
  echo "## Layer 1 skip breakdown"
  awk -F'|' '$1=="L1"{count[$2]++} END{for (k in count) print "- " k ": " count[k]}' "$TMP_COUNTS"
  echo
  echo "## Layer 2 decision breakdown"
  awk -F'|' '$1=="L2"{count[$2]++} END{for (k in count) print "- " k ": " count[k]}' "$TMP_COUNTS"
  echo
  echo "## Layer 2 reason breakdown"
  awk -F'|' '$1=="L2"{key=$2 " / " $3; count[key]++} END{for (k in count) print "- " k ": " count[k]}' "$TMP_COUNTS"
  echo
  echo "_상세는 ${REPORT_JSON} 참고._"
} > "$REPORT_MD"

echo "Backtest complete. Report: $REPORT_MD"
