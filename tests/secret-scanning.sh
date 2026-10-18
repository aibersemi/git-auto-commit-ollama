#!/usr/bin/env bash
# Exercise the real matcher and CLI with isolated Git state and mocked network calls.
# The dynamically loaded library consumes runtime configuration variables.
# shellcheck disable=SC2034
set -euo pipefail
umask 0002

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
git config --file "$test_root/clone.config" --add safe.directory "$project_dir"
git config --file "$test_root/clone.config" --add safe.directory "$project_dir/.git"
GIT_CONFIG_GLOBAL="$test_root/clone.config" git clone --quiet --no-hardlinks "$project_dir" "$test_root/repo"

[[ "$(tail -n 1 "$project_dir/git-ai.sh")" == 'main "$@"' ]]
sed '$d' "$project_dir/git-ai.sh" > "$test_root/library.sh"
cp "$project_dir/git-ai.sh" "$test_root/git-ai.sh"
cat > "$test_root/git-ai.conf" <<'CONFIG'
DEFAULT_MODEL="test-model"
DEFAULT_OLLAMA_HOST="http://localhost:11434"
FALLBACK_OLLAMA_HOST=""
USE_STRUCTURED_OUTPUT=1
NON_AI_PARALLELISM=2
CONFIG
# shellcheck source=/dev/null
source "$test_root/library.sh"
cd -- "$test_root/repo"
export GIT_INDEX_FILE="$test_root/fixture-index"
original_refs=$(git show-ref)
original_index=$(git hash-object .git/index)
passed=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3"; }
assert_absent() { [[ "$1" != *"$2"* ]] || fail "$3"; }
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
assignment() { printf '%s = %s' "$1" "$2"; }
stage_text() {
  local blob
  blob=$(printf '%s\n' "$2" | git hash-object -w --stdin)
  git update-index --add --cacheinfo 100644 "$blob" "$1"
}
start_case() {
  unset TEST_BASE_TREE
  git read-tree HEAD
  FORCE=0
  FORCE_DIFF=0
  DRY_RUN=0
  ALLOW_SECRET_COMMIT=0
  RESOLVED_NON_AI_PARALLELISM=2
  MOCK_GITLEAKS_FINDING=0
}
expect_safe() {
  local path="$1" content="$2" label="$3"
  start_case
  stage_text "$path" "$content"
  if git --literal-pathspecs diff --cached --quiet -- "$path"; then fail "$label: fixture has no staged changes"; fi
  [[ -z "$(detect_staged_secret_lines)" ]] || fail "$label: guard rejected expression/placeholder"
  if detect_sensitive_patterns; then fail "$label: global safe mode activated"; fi
  if has_sensitive_patterns "$content" "$path"; then fail "$label: per-file matcher rejected content"; fi
  select_commit_references 2> "$test_root/references.log"
  assert_equal "$REFERENCE_SENSITIVE_SKIPPED" 0 "$label: safe reference excluded"
  assert_equal "${REFERENCE_PATHS[0]:-}" "$path" "$label: reference not retained"
  pass "$label"
}
expect_sensitive() {
  local path="$1" content="$2" label="$3" report
  start_case
  stage_text "$path" "$content"
  if git --literal-pathspecs diff --cached --quiet -- "$path"; then fail "$label: fixture has no staged changes"; fi
  report=$(detect_staged_secret_lines)
  assert_equal "$report" "$path:1 potential secret on added line" "$label: missing/redaction-invalid report"
  detect_sensitive_patterns || fail "$label: global safe mode did not activate"
  has_sensitive_patterns "$content" "$path" || fail "$label: per-file matcher missed content"
  select_commit_references 2> "$test_root/references.log"
  assert_equal "$REFERENCE_SENSITIVE_SKIPPED" 1 "$label: unsafe reference retained"
  pass "$label"
}

# Synthetic values and provider markers are assembled at runtime, never stored as credentials.
literal_value=$(printf 'a%.0s' {1..24})
provider_value="gh""p_$(printf 'b%.0s' {1..32})"
key_marker="BEGIN"" SAMPLE"" PRIVATE KEY"

mkdir "$test_root/bin" "$test_root/requests"
export TEST_REAL_GIT
TEST_REAL_GIT=$(command -v git)
export TEST_REQUEST_DIR="$test_root/requests"
export TEST_MUTATION_LOG="$test_root/mutations.log"
export TEST_GITLEAKS_LOG="$test_root/gitleaks.log"
export MOCK_GITLEAKS_FINDING=0
cat > "$test_root/bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
arguments=()
for argument in "$@"; do
  case "$argument" in
    commit|push)
      printf '%s\n' "$argument" >> "$TEST_MUTATION_LOG"
      exit 99
      ;;
  esac
  arguments+=("$argument")
  if [[ "$argument" == --cached && -n "${TEST_BASE_TREE:-}" ]]; then
    arguments+=("$TEST_BASE_TREE")
  fi
done
exec "$TEST_REAL_GIT" "${arguments[@]}"
MOCK_GIT
cat > "$test_root/bin/gitleaks" <<'MOCK_GITLEAKS'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'protect --staged --redact --no-banner' ]] || exit 98
printf 'scanned\n' >> "$TEST_GITLEAKS_LOG"
if [[ "${MOCK_GITLEAKS_FINDING:-0}" == 1 ]]; then
  printf 'external scanner found a potential secret\n'
  exit 1
fi
MOCK_GITLEAKS
cat > "$test_root/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
payload='{}'
output_file=''
http_output=0
url=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) payload="$2"; shift 2 ;;
    -o) output_file="$2"; shift 2 ;;
    -w) http_output=1; shift 2 ;;
    --connect-timeout|--max-time|-H) shift 2 ;;
    http://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */api/tags|*/api/ps) body='{"models":[{"name":"test-model"}]}' ;;
  */api/chat)
    if jq -e '.messages | length > 0' >/dev/null <<<"$payload"; then
      request_file=$(mktemp "$TEST_REQUEST_DIR/request.XXXXXX")
      printf '%s\n' "$payload" > "$request_file"
    fi
    commit_type=fix
    if jq -er '.messages[1].content' <<<"$payload" | grep -Fq 'Primary staged work category: test'; then
      commit_type=test
    fi
    bullets='[]'
    if jq -e '.format.properties.bullets.minItems > 0' >/dev/null <<<"$payload"; then
      bullets='["Preserve runtime status handling."]'
    fi
    content=$(jq -nc --arg type "$commit_type" --argjson bullets "$bullets" '{type:$type,summary:"preserve runtime status handling",bullets:$bullets}')
    body=$(jq -nc --arg content "$content" '{model:"test-model",done:true,message:{content:$content}}')
    ;;
  *) printf 'Unexpected network request\n' >&2; exit 98 ;;
esac
if [[ -n "$output_file" ]]; then printf '%s\n' "$body" > "$output_file"; else printf '%s\n' "$body"; fi
[[ "$http_output" == 0 ]] || printf '200'
MOCK_CURL
chmod +x "$test_root/bin/git" "$test_root/bin/gitleaks" "$test_root/bin/curl"
export PATH="$test_root/bin:$PATH"

# Use a separate fixture path so clean checkouts stage the entire test source.
expect_safe tests/fixtures/secret-scanning.sh "$(cat "$project_dir/tests/secret-scanning.sh")" 'Secret-scanning test source is safe to scan'

for expression in \
  'secrets.token_urlsafe(16)' 'secrets.token_hex(32)' \
  'os.environ.get("WHATSAPP_ACCESS_TOKEN")' 'os.environ["ACCESS_TOKEN"]' \
  'settings.DATABASE_PASSWORD' 'config.api_key' 'CONFIGURED_TOKEN'; do
  expect_safe src/runtime.py "$(assignment self.secret "$expression")" "Python expression: $expression"
done
expect_safe tests/test_archive.py "$(assignment SECRET_KEY 'secrets.token_urlsafe(32), SECRET_KEY_FALLBACKS=[old_key]')" 'Saqqina settings override regression'
for extension in js jsx mjs cjs ts tsx mts cts; do
  expect_safe "src/runtime.$extension" "$(assignment access_token 'process.env.ACCESS_TOKEN;')" "Environment reference in .$extension"
done
expect_safe src/runtime.ts "$(assignment api_key 'config.api_key,')" 'Member reference followed by punctuation'
expect_safe 'tests/space name.py' "$(assignment self.secret 'secrets.token_urlsafe (16)')" 'Function call with whitespace and spaced path'
expect_safe $'tests/tab\tnewline\nbackslash\\name.py' "$(assignment self.secret 'secrets.token_hex(32)')" 'NUL-delimited paths preserve expression exemptions'

otp_salt=$(assignment PASSWORD_RESET_OTP_SALT '"accounts.customer-password-reset-otp"')
token_salt=$(assignment PASSWORD_RESET_TOKEN_SALT '"accounts.customer-password-reset-token"')
salt_content="$otp_salt"$'\n'"$token_salt"
expect_safe src/accounts.py "$salt_content" 'Django password-reset HMAC namespace salts are public labels'
expect_safe src/accounts.py "$otp_salt # noqa: S105 - Salt namespace." 'Namespace salt followed by a lint comment'
expect_safe src/accounts.py "$(assignment self.password_reset_otp_salt "'accounts.customer-password-reset-otp'")" 'Single-quoted namespace salt on a member'
for extension in js jsx mjs cjs ts tsx mts cts; do
  expect_safe "src/runtime.$extension" "const $otp_salt;" "Namespace salt in .$extension"
done
expect_safe src/runtime.ts "$(printf '{ "%s": "%s" }' PASSWORD_RESET_OTP_SALT accounts.customer_password_reset_otp)" 'Quoted namespace salt property with underscore-separated words'
for path in .env settings.yaml unknown.data; do
  expect_sensitive "$path" "$otp_salt" "Namespace-looking config value remains protected in $path"
done
for candidate in "$literal_value" "accounts.$literal_value" "accounts.customer-password-reset-otp-$literal_value" 'accounts.unrelated-public-label' 'accounts.customerpassword-reset-otp'; do
  expect_sensitive src/accounts.py "$(assignment PASSWORD_RESET_OTP_SALT "\"$candidate\"")" 'Salt suffix cannot exempt arbitrary values'
done
expect_sensitive src/accounts.py "$(assignment PASSWORD_RESET_OTP_SALT "\"$literal_value\"") # noqa: S105 - Salt namespace." 'Lint suppression cannot exempt a salt credential'
expect_sensitive src/accounts.py "$(assignment PASSWORD_RESET_OTP_SALT '"accounts.customer-password-reset-otp')" 'Unterminated namespace salt remains protected'
expect_sensitive src/accounts.py "$(assignment PASSWORD_RESET_OTP_SALT "\"accounts.customer-password-reset-otp\" + \"$literal_value\"")" 'Concatenated namespace salt remains protected'
expect_sensitive src/accounts.py "$(assignment PASSWORD_RESET_OTP_SALT "\"accounts.$provider_value.password-reset-otp\"")" 'Provider signature overrides namespace salt exemption'
expect_sensitive src/accounts.py "$(assignment PASSWORD_RESET_OTP '"accounts.customer-password-reset-otp"')" 'Namespace-looking credential without a salt suffix remains protected'
for order in first last; do
  sensitive_line=$(assignment password "\"$literal_value\"")
  if [[ "$order" == first ]]; then mixed_line="$otp_salt; $sensitive_line"; else mixed_line="$sensitive_line; $otp_salt"; fi
  expect_sensitive src/accounts.py "$mixed_line" "Multiple candidates with namespace salt $order"
done

start_case
stage_text src/accounts.py "$salt_content"
export TEST_BASE_TREE
TEST_BASE_TREE=$(git write-tree)
stage_text src/accounts.py "$otp_salt # namespace"$'\n'"$token_salt"
[[ -z "$(detect_staged_secret_lines)" ]] || fail 'Namespace salt edit triggered the guard'
if detect_sensitive_patterns; then fail 'Removed/context namespace salts activated safe mode'; fi
pass 'Full diff treats removed and unchanged namespace salts as public labels'

oauth_label='OAUTH_GOOGLE_CLIENT_SECRET'
oauth_id_label='OAUTH_GOOGLE_CLIENT_ID'
ternary_content=$(printf 'const path = [hasClientId ? "%s" : "%s"];' "$oauth_label" "$oauth_id_label")
expect_safe src/runtime.ts "$ternary_content" 'OAuth environment names in a TypeScript ternary are labels'
# The JavaScript template interpolation is literal fixture content.
# shellcheck disable=SC2016
expect_safe src/runtime.ts "$(printf 'throw new Error(`Invalid environment: ${hasClientId ? "%s" : "%s"}`);' "$oauth_label" "$oauth_id_label")" 'OAuth environment names in a template interpolation are labels'
expect_safe src/runtime.ts "$(printf "const path = [hasClientId ? '%s' : '%s'];" "$oauth_label" "$oauth_id_label")" 'Single-quoted environment labels in a ternary'
expect_safe src/runtime.ts "$(printf 'const path = [hasClientId ? "%s" : "%s", hasToken ? "%s" : "%s"];' "$oauth_label" "$oauth_id_label" ACCESS_TOKEN AUTH_TOKEN)" 'Multiple ternary labels on one line'
for quote in '"' "'"; do
  expect_sensitive src/runtime.ts "const config = { $quote""OAUTH_GOOGLE_CLIENT_SECRET$quote: $quote$literal_value$quote };" 'Quoted object properties still protect credential literals'
done
expect_sensitive src/runtime.ts "$ternary_content $(assignment password "\"$literal_value\"")" 'Ternary label cannot hide another credential on the same line'
expect_sensitive src/runtime.ts "$(printf 'const name = hasClientId ? "%s" : "%s";' "$oauth_label" "$provider_value")" 'Provider signature overrides ternary label exemption'
expect_sensitive unknown.data "$ternary_content" 'Unknown files do not receive ternary syntax exemptions'

for quote in '"' "'"; do
  expect_safe tests/runtime.test.ts "$(assignment OAUTH_GOOGLE_CLIENT_SECRET "$quote""client-secret$quote")," 'Exact OAuth client-secret placeholder in source'
done
for path in .env settings.yaml unknown.data; do
  expect_sensitive "$path" "$(assignment OAUTH_GOOGLE_CLIENT_SECRET '"client-secret"')" "OAuth placeholder-looking config value remains protected in $path"
done
for candidate in client-secret-production client-secret-123456789012 "client-secret-$literal_value"; do
  expect_sensitive tests/runtime.test.ts "$(assignment OAUTH_GOOGLE_CLIENT_SECRET "\"$candidate\"")" 'OAuth placeholder prefix cannot exempt arbitrary values'
done
expect_sensitive src/runtime.ts "$(assignment OAUTH_GOOGLE_CLIENT_SECRET "\"client-secret\" + \"$literal_value\"")" 'OAuth placeholder cannot exempt a concatenated credential'
expect_sensitive src/runtime.ts "$(assignment OAUTH_GOOGLE_CLIENT_SECRET '"client-secret')" 'Unterminated OAuth placeholder remains protected'

for placeholder in '"dummy-secret-value"' '"your-api-key-here"' 'changeme-secret-value'; do
  expect_safe .env "$(assignment password "$placeholder")" "Placeholder candidate: $placeholder"
done
environment_value=$(printf '$%s' '{ACCESS_TOKEN}')
expect_safe .env "$(assignment access_token "$environment_value")" 'Environment interpolation contains no literal'

synthetic_content="override_settings($(assignment WHATSAPP_DEEPSEEK_API_KEY '"credential-sintetis-khusus-test"')),"
expect_safe tests/test_workflow.py "$synthetic_content" 'Saqqina synthetic credential regression'
for placeholder in 'synthetic-api-key-for-tests' 'SYNTHETIC_TEST_TOKEN' 'password_sintetis_untuk_test'; do
  expect_safe src/runtime.py "$(assignment api_key "\"$placeholder\"")" 'Explicit synthetic placeholder vocabulary'
done
expect_safe src/runtime.ts "$(assignment api_key "'synthetic-api-key-for-tests';")" 'Single-quoted synthetic placeholder in TypeScript'
expect_safe src/runtime.py "$(assignment api_key '"synthetic-token"') # runtime configuration" 'Synthetic placeholder followed by a comment'
for path in .env settings.yaml unknown.data; do
  expect_sensitive "$path" "$(assignment api_key '"synthetic-api-key-for-tests"')" "Synthetic-looking config value remains protected in $path"
done
for candidate in \
  "credential-synthetic-$literal_value" \
  "${literal_value}-synthetic-credential" \
  'synthetic-credential-production' \
  'synthetic-credential-123456789012' \
  'synthetic-for-tests' \
  'credential-only-for-tests'; do
  expect_sensitive tests/test_workflow.py "$(assignment api_key "\"$candidate\"")" 'Synthetic marker alone cannot exempt arbitrary values'
done
expect_sensitive src/runtime.py "$(assignment api_key '"synthetic-token')" 'Unterminated synthetic literal remains protected'
expect_sensitive src/runtime.py "$(assignment api_key "\"synthetic-token\" + \"$literal_value\"")" 'Synthetic prefix cannot exempt a concatenated credential'
expect_sensitive src/runtime.py "$(assignment api_key "\"synthetic-token-$provider_value\"")" 'Provider signature overrides synthetic placeholder vocabulary'
for order in first last; do
  placeholder_line=$(assignment api_key '"synthetic-api-key-for-tests"')
  sensitive_line=$(assignment password "\"$literal_value\"")
  if [[ "$order" == first ]]; then mixed_line="$placeholder_line; $sensitive_line"; else mixed_line="$sensitive_line; $placeholder_line"; fi
  expect_sensitive tests/test_workflow.py "$mixed_line" "Multiple candidates with synthetic placeholder $order"
done

vapid_label='WEB_PUSH_VAPID_PRIVATE_KEY'
notification_content=$(printf '@override_settings(\n    %s,\n)' "$(assignment "$vapid_label" '"test-private-key"')")
expect_safe tests/test_notifications.py "$notification_content" 'Web Push private-key test fixture regression'
for placeholder in test-private-key test-public-key test-auth-key test-api-key TEST_SECRET_VALUE testing-private-key tests-private-key; do
  for quote in '"' "'"; do
    expect_safe src/runtime.py "$(assignment "$vapid_label" "$quote$placeholder$quote")" "Complete test-prefixed credential label: $quote$placeholder$quote"
  done
done
for extension in pyi js jsx mjs cjs ts tsx mts cts; do
  expect_safe "src/runtime.$extension" "$(assignment "$vapid_label" '"test-private-key"')," "Test-prefixed credential label in .$extension"
done
expect_safe src/runtime.ts "$(printf '{ "%s": "%s" }' "$vapid_label" test-private-key)" 'Test-prefixed placeholder in a quoted object property'
for path in .env production.env settings.ini settings.conf settings.yaml settings.json unknown.data; do
  expect_sensitive "$path" "$(assignment "$vapid_label" '"test-private-key"')" "Test-prefixed config value remains protected in $path"
done
for candidate in \
  "test-private-key-$literal_value" \
  "$literal_value-test-private-key" \
  'test-private-key-production' \
  'test-private-key-123456789012' \
  'test-private-material' \
  'test-public-label' \
  'public-private-key' \
  'private-key-for-testing'; do
  expect_sensitive tests/test_notifications.py "$(assignment "$vapid_label" "\"$candidate\"")" 'Test marker alone cannot exempt arbitrary values'
done
expect_sensitive src/runtime.py "$(assignment "$vapid_label" '"test-private-key')" 'Unterminated test-prefixed placeholder remains protected'
expect_sensitive src/runtime.py "$(assignment "$vapid_label" 'test-private-key')" 'Unquoted test-prefixed text remains protected'
expect_sensitive src/runtime.py "$(assignment "$vapid_label" "\"test-private-key\" + \"$literal_value\"")" 'Test prefix cannot exempt a concatenated credential'
for signature in "$provider_value" "$key_marker"; do
  expect_sensitive tests/test_notifications.py "$(assignment "$vapid_label" "\"test-private-key-$signature\"")" 'Provider/key signature overrides test-prefixed placeholder'
done
for order in first last; do
  placeholder_line=$(assignment "$vapid_label" '"test-private-key"')
  sensitive_line=$(assignment password "\"$literal_value\"")
  if [[ "$order" == first ]]; then mixed_line="$placeholder_line; $sensitive_line"; else mixed_line="$sensitive_line; $placeholder_line"; fi
  expect_sensitive tests/test_notifications.py "$mixed_line" "Multiple candidates with test-prefixed placeholder $order"
done

start_case
stage_text tests/test_notifications.py "$notification_content"
export TEST_BASE_TREE
TEST_BASE_TREE=$(git write-tree)
for scenario in removed context; do
  if [[ "$scenario" == removed ]]; then
    stage_text tests/test_notifications.py '# Test the notification guard.'
  else
    stage_text tests/test_notifications.py "$notification_content"$'\n# Test the notification guard.'
  fi
  [[ -z "$(detect_staged_secret_lines)" ]] || fail "$scenario: test-prefixed placeholder edit triggered the guard"
  if detect_sensitive_patterns; then fail "$scenario: test-prefixed placeholder activated safe mode"; fi
  pass "Full diff treats $scenario test-prefixed placeholders as labels"
done

for quote in '"' "'"; do
  expect_sensitive tests/test_archive.py "$(assignment password "$quote$literal_value$quote")" 'Quoted literal in tests is protected'
done
for path in .env production.env settings.ini settings.conf settings.yaml unknown.data; do
  expect_sensitive "$path" "$(assignment password "$literal_value")" "Unquoted literal in $path"
done
expect_sensitive settings.json "$(printf '{"%s": "%s"}' password "$literal_value")" 'JSON quoted property name'
expect_sensitive .env "$(assignment password settings.DATABASE_PASSWORD)" 'Config member-like text remains literal'
expect_sensitive unknown.data "$(assignment SECRET_KEY 'secrets.token_urlsafe(32)')" 'Unknown file type has no code exemptions'
expect_sensitive src/runtime.py "$(assignment password '"settings.DATABASE_PASSWORD"')" 'Quoted expression-like text remains literal'
expect_sensitive .env "$(assignment password "$literal_value") # dummy example" 'Placeholder comment cannot hide a literal'
for order in first last; do
  placeholder_line=$(assignment api_key '"dummy-secret-value"')
  sensitive_line=$(assignment password "\"$literal_value\"")
  if [[ "$order" == first ]]; then mixed_line="$placeholder_line; $sensitive_line"; else mixed_line="$sensitive_line; $placeholder_line"; fi
  expect_sensitive src/runtime.py "$mixed_line" "Multiple candidates with placeholder $order"
done

signature_index=0
for signature in \
  "$provider_value" \
  "github""_pat_$(printf 'c%.0s' {1..24})" \
  "AK""IA$(printf 'A%.0s' {1..16})" \
  "xox""b-$(printf 'd%.0s' {1..16})" \
  "AI""za$(printf 'e%.0s' {1..35})" \
  "sk""-$(printf 'f%.0s' {1..24})" \
  "ey""J$(printf 'g%.0s' {1..12}).$(printf 'h%.0s' {1..12}).$(printf 'i%.0s' {1..12})" \
  "$key_marker"; do
  signature_index=$((signature_index + 1))
  expect_sensitive src/runtime.py "$(printf 'note = "example %s"' "$signature")" "Provider/key signature $signature_index overrides placeholder text"
done
expect_sensitive src/runtime.py "$(assignment api_key "settings.KEY + \"$provider_value\"")" 'Provider signature overrides expression exemption'
expect_sensitive src/runtime.py "$(assignment api_key "config.load(password=\"$literal_value\")")" 'Nested literal argument remains protected'

start_case
stage_text src/runtime.py $'status = "ready"\n'"$(assignment password "\"$literal_value\"")"$'\nstatus_reason = "idle"'
export TEST_BASE_TREE
TEST_BASE_TREE=$(git write-tree)
for scenario in removed context; do
  if [[ "$scenario" == removed ]]; then
    stage_text src/runtime.py $'status = "ready"\nstatus_reason = "active"'
  else
    stage_text src/runtime.py $'status = "ready"\n'"$(assignment password "\"$literal_value\"")"$'\nstatus_reason = "active"'
  fi
  [[ -z "$(detect_staged_secret_lines)" ]] || fail "$scenario: guard scanned a non-added credential"
  detect_sensitive_patterns || fail "$scenario: safe mode missed full-diff credential"
  select_commit_references 2> "$test_root/references.log"
  assert_equal "$REFERENCE_SENSITIVE_SKIPPED" 1 "$scenario: credential-containing reference retained"
  pass "Full diff protects $scenario lines without blocking harmless additions"
done

if has_sensitive_patterns "$(assignment password settings.DATABASE_PASSWORD)" src/runtime.py old.env; then
  pass 'Config-to-code rename keeps conservative full-diff matching'
else
  fail 'Config-to-code rename lost literal protection'
fi

start_case
stage_text src/runtime.py "$(assignment self.secret 'secrets.token_urlsafe(16)')"
stage_text .env "$(assignment password "$literal_value")"
assert_equal "$(detect_staged_secret_lines)" '.env:1 potential secret on added line' 'Per-file language context leaked between files'
pass 'Mixed source and config changes retain separate syntax rules'

# Policy tests stop before commit/push and use mocked AI even in preview mode.
cli_options=(--no-stage --no-push --no-pull --no-banner --no-file-analysis)
run_cli() {
  local status=0
  rm -f "$test_root"/requests/request.* "$TEST_MUTATION_LOG"
  bash "$test_root/git-ai.sh" "${cli_options[@]}" "$@" > "$test_root/cli.out" 2> "$test_root/cli.err" || status=$?
  [[ ! -e "$TEST_MUTATION_LOG" ]] || fail 'CLI attempted commit/push'
  CLI_STATUS="$status"
}

start_case
safe_content=$'status = "ready"\n'"$(assignment self.secret 'secrets.token_urlsafe(16)')"
stage_text src/runtime.py "$safe_content"
index_before=$(git hash-object "$GIT_INDEX_FILE")
run_cli --dry-run
assert_equal "$CLI_STATUS" 0 'Benign preview failed'
assert_absent "$(cat "$test_root/cli.err")" 'Potential secrets detected' 'Benign preview guard warning'
assert_absent "$(cat "$test_root/cli.err")" 'Safe mode enabled' 'Benign preview lost primary context'
requests=$(cat "$test_root"/requests/request.*)
assert_contains "$requests" 'secrets.token_urlsafe(16)' 'Benign expression missing from AI context'
assert_equal "$(git hash-object "$GIT_INDEX_FILE")" "$index_before" 'Benign preview changed the caller index'
pass 'Benign CLI preview retains source context without Git mutations'

start_case
stage_text tests/test_workflow.py "$synthetic_content"
index_before=$(git hash-object "$GIT_INDEX_FILE")
run_cli --dry-run
assert_equal "$CLI_STATUS" 0 'Synthetic placeholder preview failed'
assert_absent "$(cat "$test_root/cli.err")" 'Potential secrets detected' 'Synthetic placeholder triggered the guard'
assert_absent "$(cat "$test_root/cli.err")" 'Safe mode enabled' 'Synthetic placeholder activated safe mode'
assert_contains "$(cat "$test_root"/requests/request.*)" 'credential-sintetis-khusus-test' 'Synthetic placeholder missing from AI context'
assert_equal "$(git hash-object "$GIT_INDEX_FILE")" "$index_before" 'Synthetic placeholder preview changed the caller index'
pass 'Synthetic placeholder CLI preview preserves useful context and Git state'

start_case
stage_text tests/test_notifications.py "$notification_content"
index_before=$(git hash-object "$GIT_INDEX_FILE")
run_cli --dry-run
assert_equal "$CLI_STATUS" 0 'Test-prefixed placeholder preview failed'
assert_absent "$(cat "$test_root/cli.err")" 'Potential secrets detected' 'Test-prefixed placeholder triggered the guard'
assert_absent "$(cat "$test_root/cli.err")" 'Safe mode enabled' 'Test-prefixed placeholder activated safe mode'
assert_contains "$(cat "$test_root"/requests/request.*)" 'test-private-key' 'Test-prefixed placeholder missing from AI context'
assert_equal "$(git hash-object "$GIT_INDEX_FILE")" "$index_before" 'Test-prefixed placeholder preview changed the caller index'
pass 'Test-prefixed placeholder CLI preview preserves useful context and Git state'

start_case
stage_text src/runtime.ts "$ternary_content"
stage_text tests/runtime.test.ts "$(printf 'const config = { %s: "%s" };' "$oauth_label" client-secret)"
index_before=$(git hash-object "$GIT_INDEX_FILE")
run_cli --dry-run
assert_equal "$CLI_STATUS" 0 'OAuth environment preview failed'
assert_absent "$(cat "$test_root/cli.err")" 'Potential secrets detected' 'OAuth environment names or placeholder triggered the guard'
assert_absent "$(cat "$test_root/cli.err")" 'Safe mode enabled' 'OAuth environment preview activated safe mode'
assert_contains "$(cat "$test_root"/requests/request.*)" 'OAUTH_GOOGLE_CLIENT_SECRET' 'OAuth environment source missing from AI context'
assert_equal "$(git hash-object "$GIT_INDEX_FILE")" "$index_before" 'OAuth environment preview changed the caller index'
pass 'OAuth environment CLI preview preserves source context and Git state'

start_case
stage_text src/accounts.py "$salt_content"
export TEST_BASE_TREE
TEST_BASE_TREE=$(git write-tree)
stage_text src/accounts.py "$otp_salt # namespace"$'\n'"$token_salt # namespace"
index_before=$(git hash-object "$GIT_INDEX_FILE")
run_cli --dry-run
assert_equal "$CLI_STATUS" 0 'Namespace salt preview failed'
assert_absent "$(cat "$test_root/cli.err")" 'Potential secrets detected' 'Namespace salt triggered the guard'
assert_absent "$(cat "$test_root/cli.err")" 'Safe mode enabled' 'Namespace salt activated safe mode'
assert_contains "$(cat "$test_root"/requests/request.*)" 'accounts.customer-password-reset-otp' 'Namespace salt missing from AI context'
assert_equal "$(git hash-object "$GIT_INDEX_FILE")" "$index_before" 'Namespace salt preview changed the caller index'
pass 'Namespace salt CLI preview preserves source context and Git state'

start_case
stage_text src/runtime.py "$(assignment password "\"$literal_value\"")"
staging_before=$(git ls-files --stage -z | git hash-object --stdin)
run_cli
assert_equal "$CLI_STATUS" 1 'Normal invocation did not block a literal'
assert_contains "$(cat "$test_root/cli.err")" 'Commit cancelled' 'Normal invocation missed guard cancellation'
if compgen -G "$test_root/requests/request.*" >/dev/null; then fail 'Blocked invocation sent a generation prompt'; fi
assert_absent "$(cat "$test_root/cli.err")" "$literal_value" 'Guard exposed a literal in its report'
assert_equal "$(git ls-files --stage -z | git hash-object --stdin)" "$staging_before" 'Blocked invocation changed staged content'
pass 'Normal CLI blocks before generation, commit, or push and redacts reports'

index_before=$(git hash-object "$GIT_INDEX_FILE")
run_cli --dry-run
assert_equal "$CLI_STATUS" 0 'Sensitive preview failed'
assert_contains "$(cat "$test_root/cli.err")" 'Safe mode enabled' 'Sensitive preview did not enable safe mode'
assert_contains "$(cat "$test_root/cli.err")" 'commit would be blocked normally' 'Sensitive preview missed guard warning'
assert_absent "$(cat "$test_root"/requests/request.*)" "$literal_value" 'Sensitive preview exposed the literal to AI'
assert_equal "$(git hash-object "$GIT_INDEX_FILE")" "$index_before" 'Sensitive preview changed the caller index'
pass 'Sensitive CLI preview continues safely with an isolated index'

(
  DRY_RUN=0
  ALLOW_SECRET_COMMIT=1
  enforce_staged_secret_policy 2> "$test_root/override.err"
  detect_sensitive_patterns || fail 'Secret-commit override disabled safe mode'
)
assert_contains "$(cat "$test_root/override.err")" 'Secret commit allowed' 'Secret-commit override stopped working'
pass 'Secret-commit override remains independent of safe mode'

start_case
stage_text tests/test_workflow.py "$synthetic_content"
MOCK_GITLEAKS_FINDING=1
run_cli
assert_equal "$CLI_STATUS" 1 'External finding did not block'
assert_contains "$(cat "$test_root/cli.err")" 'gitleaks found a potential secret' 'External finding missing from policy report'
[[ -s "$TEST_GITLEAKS_LOG" ]] || fail 'External scanner was not called'
pass 'External scanner still supplements the built-in guard'

start_case
stage_text tests/test_notifications.py "$notification_content"
MOCK_GITLEAKS_FINDING=1
run_cli
assert_equal "$CLI_STATUS" 1 'External finding on a test-prefixed placeholder did not block'
assert_contains "$(cat "$test_root/cli.err")" 'gitleaks found a potential secret' 'External test-prefixed finding missing from policy report'
pass 'External scanner findings remain independent of test-prefixed placeholders'

assert_equal "$(git hash-object .git/index)" "$original_index" 'Original clone index changed'
assert_equal "$(git show-ref)" "$original_refs" 'Original refs changed'
printf 'All %s secret scanning regression scenarios passed.\n' "$passed"
