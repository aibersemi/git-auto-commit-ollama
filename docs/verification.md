# Verification

[Documentation index](../README.md#documentation)

## Documentation Verification

1. Compare all changed statements and examples with the current CLI help and implementation, configuration, Makefile targets, tests, and workflows as applicable. Verify control boundaries such as staging, commit, push, scanner overrides, and endpoint selection against their entry points.
2. Render the affected Markdown with a GitHub Flavored Markdown preview. Check headings, list nesting, tables, code fences, and any diagrams. Check every relative target and heading anchor in the affected guides, and search the repository for incoming references to moved files and renamed headings.
3. Verify the [README index](../README.md#documentation) reaches every guide and that descriptions of defaults, contracts, and procedures link back to their canonical owner in [Architecture](architecture.md#documentation-ownership).
4. Check English wording and line formatting against [AGENTS.md](../AGENTS.md#documentation). Run `git diff --check` and inspect new Markdown files for trailing whitespace or consecutive blank lines, since untracked files do not appear in the default diff.
5. Review the changed paths and confirm the documentation patch leaves application code, runtime configuration, and workflows untouched. Documentation-only verification requires no service restart or live Ollama smoke test.

## Local Checks

Run these checks from the project root for Bash changes. Install `shellcheck` for Bash linting. The [installation guide](installation.md#prerequisites) lists runtime tools, and [CI](automation.md#continuous-integration) identifies the pinned tools used by GitHub Actions.

```bash
bash -n git-ai.sh
shellcheck git-ai.sh
./git-ai.sh --help >/tmp/git-ai-help.txt
```

Run the relevant suites for changes to behavior, and lint any test scripts you change.

```bash
for test_file in tests/*.sh; do
  bash -n "$test_file" || exit 1
  shellcheck "$test_file" || exit 1
  bash "$test_file" || exit 1
done
```

| Suite | What it verifies |
| --- | --- |
| [`tests/markdown-references.sh`](../tests/markdown-references.sh) | Classification and ranked references, full-diff and chunked paths, response validation and retries, and worker limits and UI progress. Checks that dry-run staging preserves the original index, refs, and object database and removes temporary files after success or a scanner failure. Uses mocked Ollama. |
| [`tests/secret-scanning.sh`](../tests/secret-scanning.sh) | Commit policy, safe previews, scanner failures, full-diff screening, fixture and expression handling, and bounded scans of very long lines. Uses mocked Ollama and Gitleaks and isolated indexes. |
| [`tests/gitleaks-integration.sh`](../tests/gitleaks-integration.sh) | Actual staged scans and redaction, report handling, relative invocation paths, repository configuration, precedence, includes, and ignores. Checks that Gitleaks reads temporary blobs when dry-run starts from a subdirectory with a split index and a custom object directory. Requires the installed Gitleaks binary. |

These suites operate on temporary repositories without creating real commits, pushing, or contacting a live Ollama endpoint. Keep synthetic credential markers assembled at runtime, sanitized reports free of values, and command mocks scoped to the isolated tests.

## Targeted Regression Checks

- **References and generation.** Cover docs-only, tests, CI, mixed runtime and Markdown, and absent or cosmetic Markdown. Verify ranking before truncation, Unicode handling, source context order, and category-aware quality rejection. Confirm that fitting full diffs skip analysis and that oversized input uses ordered, bounded chunks, consolidation, and fallback. Exercise structured and plain formats, inline-code normalization, invalid body and formatting cases, visible reasons, and correction prompts. Check success after two rejections, termination on the third invalid response, and exhaustion from request failures. Failure cases should confirm a nonzero exit, bounded requests, unchanged original index and refs, lock cleanup, and no commit or push invocation.
- **Secret handling.** Verify Gitleaks findings, built-in-only matches, scan errors and malformed reports, preview and explicit override boundaries, privacy of scanner output, and protection of removed and unchanged diff context. Cover source expressions, literal fallbacks, placeholders, fences, public namespace salts, test fixtures, renames, multiple candidates, and long generated lines. Verify scanner policy precedence and relative paths from both the root and a subdirectory. See the [security contracts](security.md).
- **Ollama integration.** Exercise the primary endpoint, fallback on tags request failure, missing-model behavior with and without `--no-pull`, and final `--no-structured` handling when those paths change. Keep model settings fixed when comparing latency, token usage, request count, or output quality.
- **Workers and progress.** Use over-budget input with one file, six files, and a larger selection. Check numeric and automatic capacity, local service detection, remote hints, the one-worker foreground path, deterministic summary order, and real overlap within limits. Verify one-file requests even with a larger compatibility batch size, ordered chunks, correct request totals, local fallback, and exclusion of generated paths, binaries, and oversized blobs. Use a simulated clock to check staged-file intervals through 95%, two-second ticks through 99%, and the shared clock across analysis, generation, and retries. Use delayed mock responses to exercise queued work, out-of-order completion, unique counters, and cursor restoration. Check affected animations in a terminal dry-run when Ollama is available.
- **GitHub Actions.** Run `actionlint` and confirm the affected CI run on GitHub. Stub `gh` when testing release commands locally. Keep validation away from live release creation and live stale issue or pull request state. See [Repository Automation](automation.md).

## Isolated Runtime Smoke Test

Run from the project root when an active, trusted Ollama endpoint has the selected model available. If it is unavailable, record the live test as skipped. Use the [configuration guide](configuration.md#ollama-host-resolution) to confirm the endpoint before testing.

```bash
(
  set -e
  project_dir=$(pwd -P)
  test_repo=$(mktemp -d)
  trap 'rm -rf -- "$test_repo"' EXIT
  git init "$test_repo"
  cd "$test_repo"
  git config user.name "git-ai test"
  git config user.email "git-ai-test@example.invalid"
  printf 'hello\n' > sample.txt
  "$project_dir/git-ai.sh" --dry-run --no-push --no-banner --no-pull
)
```

Verify the preview displays a message and leaves the original index, refs, and object database intact. In this fresh repository, the index should still be absent, `git for-each-ref` should print no refs, and `git cat-file --batch-all-objects --batch-check` should print no objects. For changes to mixed references, add a changed source file and a Markdown file with at least 12 added words explaining a completed change. Confirm the CLI reports both reference kinds and that the generated subject leads with the implemented behavior. Repeat without informative Markdown to check the fallback. Use `--debug` only with non-sensitive fixtures and handle the output as described in [Debug Output](security.md#debug-output).
