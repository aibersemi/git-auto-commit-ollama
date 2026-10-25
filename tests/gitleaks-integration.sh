#!/usr/bin/env bash
# Exercise the installed Gitleaks binary without Ollama, commits, or pushes.
# shellcheck disable=SC2034
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0
unset GIT_INDEX_FILE GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML

for dependency in git jq gitleaks; do
  command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 1; }
done
sed '$d' "$project_dir/git-ai.sh" > "$test_root/library.sh"
printf 'FALLBACK_OLLAMA_HOST=""\n' > "$test_root/git-ai.conf"
# shellcheck source=/dev/null
source "$test_root/library.sh"
git init --quiet "$test_root/repo"
cd -- "$test_root/repo"
mkdir src
printf 'hello\n' > 'src/space name.txt'
git add -- 'src/space name.txt'
original_index=$(git hash-object .git/index)
export GIT_INDEX_FILE="$test_root/isolated-index"
cp .git/index "$GIT_INDEX_FILE"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
scan() {
  SCAN_STATUS=0
  run_gitleaks_secret_scan "$test_root/report.json" || SCAN_STATUS=$?
}

scan
[[ "$SCAN_STATUS" -eq 0 ]] || fail 'Clean staged content was rejected'

# Generate a synthetic provider-shaped marker; never store a complete token.
marker="gh""p_$(printf 'abcDEF0123456789%.0s' {1..3})"
marker="${marker:0:40}"
printf '%s\n' "$marker" > 'src/space name.txt'
scan
[[ "$SCAN_STATUS" -eq 0 ]] || fail 'Unstaged content affected the scan'
git add -- 'src/space name.txt'
printf 'hello\n' > 'src/space name.txt'
scan
[[ "$SCAN_STATUS" -eq 10 ]] || fail 'Staged provider token was missed'
jq -e 'any(.[]; .File == "src/space name.txt" and .RuleID == "github-pat" and .StartLine == 1)' \
  "$test_root/report.json" >/dev/null || fail 'Finding metadata is incorrect'
if grep -Fq "$marker" "$test_root/report.json"; then fail 'JSON report was not redacted'; fi

DRY_RUN=1
enforce_staged_secret_policy 2> "$test_root/preview.err"
[[ "${GITLEAKS_SENSITIVE_PATHS[0]:-}" == 'src/space name.txt' ]] || fail 'Safe mode lost the finding path'
has_sensitive_patterns 'opaque content' 'src/space name.txt' || fail 'Gitleaks finding did not protect per-file context'
detect_sensitive_patterns || fail 'Gitleaks finding did not activate global safe mode'
if grep -Fq "$marker" "$test_root/preview.err"; then fail 'Finding report exposed a value'; fi

DRY_RUN=0
if (enforce_staged_secret_policy) 2> "$test_root/blocked.err"; then fail 'Normal policy allowed a finding'; fi
grep -Fq 'Commit cancelled' "$test_root/blocked.err" || fail 'Commit-blocking diagnostic missing'
ALLOW_SECRET_COMMIT=1
enforce_staged_secret_policy 2> "$test_root/override.err"
detect_sensitive_patterns || fail 'Commit override disabled safe mode'

# Work from a subdirectory and keep using the caller's isolated index.
(cd src; scan; [[ "$SCAN_STATUS" -eq 10 ]]) || fail 'Subdirectory scan missed staged content'

# Preserve unusual paths through JSON parsing and NUL-delimited safe-mode storage.
unusual_path=$'src/tab\tnewline\nbackslash\\name.txt'
printf '%s\n' "$marker" > "$unusual_path"
git add -- "$unusual_path"
DRY_RUN=1
enforce_staged_secret_policy 2> "$test_root/unusual.err"
has_sensitive_patterns 'opaque content' "$unusual_path" || fail 'Unusual finding path lost safe-mode protection'

# Repository configuration must be selected consistently from any directory.
assert_scan() (
  local directory="$1" expected_status="$2" source="$3" rule="${4:-}"
  cd -- "$directory"
  local caller_dir="$PWD" caller_index="$GIT_INDEX_FILE" index_before
  index_before=$(git hash-object "$GIT_INDEX_FILE")
  DEBUG=1
  scan 2> "$test_root/config-debug.err"
  [[ "$SCAN_STATUS" -eq "$expected_status" ]] || fail "$source: unexpected scan status from $directory"
  grep -Fq "Gitleaks configuration source: $source" "$test_root/config-debug.err" || fail 'Configuration source missing from debug output'
  if grep -Fq INLINE_CONTENT_MUST_STAY_PRIVATE "$test_root/config-debug.err"; then fail 'Inline configuration exposed in debug output'; fi
  [[ "$PWD" == "$caller_dir" && "$GIT_INDEX_FILE" == "$caller_index" ]] || fail 'Scanner changed caller directory or index override'
  [[ "$(git hash-object "$GIT_INDEX_FILE")" == "$index_before" ]] || fail 'Scanner changed isolated index'
  if [[ -n "$rule" ]]; then
    jq -e --arg rule "$rule" 'any(.[]; .RuleID == $rule)' "$test_root/report.json" >/dev/null || fail "Missing rule: $rule"
  fi
)

write_config() {
  local config_path="$1" rule_id="$2"
  cat > "$config_path" <<CONFIG
[extend]
useDefault = true
[[rules]]
id = "$rule_id"
regex = 'CONFIG_SCAN_MARKER_[A-Z]{16}'
CONFIG
}
config_marker="CONFIG_SCAN_""MARKER_$(printf 'Z%.0s' {1..16})"
printf '%s\n' "$config_marker" > src/configured.txt
git add -- src/configured.txt
write_config .gitleaks.toml custom-root
# A nested config must not replace the repository policy.
printf 'invalid = [\n' > src/.gitleaks.toml
assert_scan . 10 'repository root .gitleaks.toml' custom-root
assert_scan src 10 'repository root .gitleaks.toml' custom-root
jq -e 'any(.[]; .RuleID == "github-pat")' "$test_root/report.json" >/dev/null || fail 'Custom configuration lost default rules'

# Root-relative configuration includes and ignore files must also work below root.
mkdir .scanner
write_config .scanner/base.toml custom-base
printf '[extend]\npath = ".scanner/base.toml"\n' > .gitleaks.toml
assert_scan src 10 'repository root .gitleaks.toml' custom-base
jq -r '.[] | select(.RuleID == "custom-base") | .Fingerprint' "$test_root/report.json" > .gitleaksignore
assert_scan src 10 'repository root .gitleaks.toml' github-pat
jq -e 'all(.[]; .RuleID != "custom-base")' "$test_root/report.json" >/dev/null || fail 'Root ignore file was not honored'
rm .gitleaksignore

# Environment overrides keep native precedence, even with an invalid root config.
printf 'invalid = [\n' > .gitleaks.toml
write_config src/env-file.toml custom-env-file
write_config "$test_root/inline.toml" custom-inline
inline_config=$(cat "$test_root/inline.toml")$'\n# INLINE_CONTENT_MUST_STAY_PRIVATE'
GITLEAKS_CONFIG=src/env-file.toml GITLEAKS_CONFIG_TOML="$inline_config" \
  assert_scan . 10 'GITLEAKS_CONFIG (file)' custom-env-file
GITLEAKS_CONFIG=env-file.toml GITLEAKS_CONFIG_TOML="$inline_config" \
  assert_scan src 10 'GITLEAKS_CONFIG (file)' custom-env-file
GITLEAKS_CONFIG_TOML="$inline_config" assert_scan src 10 'GITLEAKS_CONFIG_TOML (inline)' custom-inline
GITLEAKS_CONFIG=missing.toml GITLEAKS_CONFIG_TOML="$inline_config" \
  assert_scan src 2 'GITLEAKS_CONFIG (file)'
GITLEAKS_CONFIG_TOML='invalid = [' assert_scan src 2 'GITLEAKS_CONFIG_TOML (inline)'
assert_scan . 2 'repository root .gitleaks.toml'
assert_scan src 2 'repository root .gitleaks.toml'

# Relative index and report paths still refer to the original invocation directory.
GIT_INDEX_FILE=../../isolated-index GITLEAKS_CONFIG=env-file.toml \
  assert_scan src 10 'GITLEAKS_CONFIG (file)' custom-env-file
GIT_DIR=../.git GIT_WORK_TREE=.. GIT_INDEX_FILE=../../isolated-index GITLEAKS_CONFIG=env-file.toml \
  assert_scan src 10 'GITLEAKS_CONFIG (file)' custom-env-file
(
  cd src
  relative_status=0
  GITLEAKS_CONFIG=env-file.toml run_gitleaks_secret_scan ../../relative-report.json || relative_status=$?
  [[ "$relative_status" -eq 10 ]] || fail 'Relative report path scan failed'
) || fail 'Relative report path changed meaning'
[[ -s "$test_root/relative-report.json" ]] || fail 'Relative report was written to the wrong directory'
rm .gitleaks.toml
assert_scan src 10 'built-in defaults' github-pat

[[ "$(git hash-object .git/index)" == "$original_index" ]] || fail 'Original index changed'
if git rev-parse --verify HEAD >/dev/null 2>&1; then fail 'Test created a commit'; fi
printf 'All real Gitleaks integration scenarios passed (version %s).\n' "$(gitleaks version)"
