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
printf 'invalid = [\n' > .gitleaks.toml
scan
[[ "$SCAN_STATUS" -eq 2 ]] || fail 'Invalid scanner configuration was treated as a finding or clean scan'

[[ "$(git hash-object .git/index)" == "$original_index" ]] || fail 'Original index changed'
if git rev-parse --verify HEAD >/dev/null 2>&1; then fail 'Test created a commit'; fi
printf 'All real Gitleaks integration scenarios passed (version %s).\n' "$(gitleaks version)"
