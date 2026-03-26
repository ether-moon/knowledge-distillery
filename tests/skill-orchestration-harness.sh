#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

if [ "$#" -ne 2 ]; then
  fail "usage: tests/skill-orchestration-harness.sh <repo-root> <fixture.json>"
fi

command -v jq >/dev/null 2>&1 || fail "jq is required"

ROOT="$(cd "$1" && pwd)"
FIXTURE="$2"

[ -f "${FIXTURE}" ] || fail "fixture not found: ${FIXTURE}"

doc_path_for() {
  local alias="$1"
  local relative_path
  relative_path="$(jq -r --arg alias "${alias}" '.documents[$alias] // empty' "${FIXTURE}")"
  [ -n "${relative_path}" ] || fail "unknown document alias '${alias}' in ${FIXTURE}"
  local absolute_path="${ROOT}/${relative_path}"
  [ -f "${absolute_path}" ] || fail "document '${alias}' not found: ${absolute_path}"
  printf '%s\n' "${absolute_path}"
}

require_contains() {
  local scenario_id="$1"
  local doc_alias="$2"
  local needle="$3"
  local doc_path
  doc_path="$(doc_path_for "${doc_alias}")"
  if ! grep -Fq -- "${needle}" "${doc_path}"; then
    fail "${scenario_id}: expected '${doc_path#${ROOT}/}' to contain snippet: ${needle}"
  fi
}

require_absent() {
  local scenario_id="$1"
  local doc_alias="$2"
  local needle="$3"
  local doc_path
  doc_path="$(doc_path_for "${doc_alias}")"
  if grep -Fq -- "${needle}" "${doc_path}"; then
    fail "${scenario_id}: expected '${doc_path#${ROOT}/}' to omit snippet: ${needle}"
  fi
}

require_ordered() {
  local scenario_id="$1"
  local doc_alias="$2"
  local ordered_json="$3"
  local doc_path
  local last_line=0
  local needle
  local line

  doc_path="$(doc_path_for "${doc_alias}")"

  while IFS= read -r needle; do
    line="$(
      { grep -n -F -- "${needle}" "${doc_path}" || true; } |
        awk -F: -v last_line="${last_line}" '$1 > last_line { print $1; exit }'
    )"
    [ -n "${line}" ] || fail "${scenario_id}: expected '${doc_path#${ROOT}/}' to contain ordered snippet: ${needle}"
    last_line="${line}"
  done < <(jq -r '.[]' <<<"${ordered_json}")
}

scenario_count=0

while IFS= read -r scenario; do
  scenario_id="$(jq -r '.id' <<<"${scenario}")"
  scenario_count=$((scenario_count + 1))

  while IFS= read -r check; do
    doc_alias="$(jq -r '.doc' <<<"${check}")"
    check_key_count="$(
      jq '[has("contains"), has("absent"), has("ordered_contains")] | map(select(. == true)) | length' <<<"${check}"
    )"

    if [ "${check_key_count}" -ne 1 ]; then
      fail "${scenario_id}: check must define exactly one of contains, absent, or ordered_contains: ${check}"
    fi

    if jq -e 'has("contains")' >/dev/null <<<"${check}"; then
      require_contains \
        "${scenario_id}" \
        "${doc_alias}" \
        "$(jq -r '.contains' <<<"${check}")"
    elif jq -e 'has("absent")' >/dev/null <<<"${check}"; then
      require_absent \
        "${scenario_id}" \
        "${doc_alias}" \
        "$(jq -r '.absent' <<<"${check}")"
    elif jq -e 'has("ordered_contains")' >/dev/null <<<"${check}"; then
      require_ordered \
        "${scenario_id}" \
        "${doc_alias}" \
        "$(jq -c '.ordered_contains' <<<"${check}")"
    else
      fail "${scenario_id}: unsupported check type: ${check}"
    fi
  done < <(jq -c '.checks[]' <<<"${scenario}")
done < <(jq -c '.scenarios[]' "${FIXTURE}")

fixture_name="$(jq -r '.name // empty' "${FIXTURE}")"
[ -n "${fixture_name}" ] || fixture_name="$(basename "${FIXTURE}" .json)"

echo "${fixture_name}: ${scenario_count} scenarios passed"
