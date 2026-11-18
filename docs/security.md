# Security Controls

[Documentation index](../README.md#documentation)

Use a local or trusted network Ollama endpoint, review the primary and fallback hosts, and keep credentials out of staged changes. Review the index before using `--no-stage` and use repository ignore rules for local secrets. Secret detection is best effort. Report suspected vulnerabilities privately through the [Security Policy](../.github/SECURITY.md).

## Data Sent to Ollama

Ollama preflight checks endpoint availability and model readiness before staging or scanning and sends no repository diff. Analysis and final generation can send file names, statuses, Git statistics and summaries, eligible complete diffs, excerpts, per-file summaries, and rejected message candidates during corrections. [Host resolution](configuration.md#ollama-host-resolution) identifies the endpoint that can receive this context. A preview uses the same network integration as a regular run.

File paths, diffs, documentation including `AGENTS.md`, analysis responses, and prior commit candidates are untrusted input to prompts. Instructions tell the model to treat them as data. That reduces prompt-injection risk without verifying the factual accuracy of the generated message. Review the final result against the staged changes.

## Gitleaks Commit Guard

Gitleaks scans staged additions before AI context collection. It uses `gitleaks git --pre-commit --staged --redact` and writes a JSON report to a private temporary directory. The CLI accepts exit code `0` with an empty report or exit code `10` with findings. Displayed findings contain only the file, line, and rule ID, limited to 20 entries plus a count of additional findings. The report is removed after processing. Raw scanner logs are suppressed even in debug mode.

A successful scan with findings blocks a regular commit by default. A missing scanner, unsupported flags, execution errors, invalid configuration, and missing, invalid, or inconsistent reports stop processing before generation, commit, or push. [Overrides](#overrides) distinguish a successful scan with findings from a failed scan.

### Scanner Configuration

The scanner runs from the repository root, even when the CLI starts in a subdirectory. Configuration priority is `GITLEAKS_CONFIG` (file), `GITLEAKS_CONFIG_TOML` (inline TOML), root `.gitleaks.toml`, then default Gitleaks rules. `GITLEAKS_CONFIG` and relative Git path overrides such as `GIT_INDEX_FILE` keep their meaning relative to the caller. Configuration includes and `.gitleaksignore` resolve from the root. Nested policy files do not take over the scan. An invalid selected configuration stops the scan. Debug output identifies the configuration source without printing inline TOML.

Configuration and ignore files come from the working tree, while scanned additions come from the index. Review custom rules, `.gitleaksignore`, and `gitleaks:allow` annotations because they affect blocking. To extend the default rules in a repository-specific configuration, include the following in the root `.gitleaks.toml`.

```toml
[extend]
useDefault = true
```

Scanner exclusions are independent of the built-in matcher. Default Gitleaks rules may miss generic passwords, so use reviewed custom rules when those patterns must block commits.

## Safe Mode

Gitleaks finding paths and matches from the built-in diff matcher activate safe mode. Safe mode removes detailed diffs and diff-derived terms from the final prompt. Metadata can still be sent, and per-file requests can still send full eligible diffs from files that pass screening. Flagged files are excluded from this analysis. The matcher alone never blocks a commit.

The CLI checks the whole candidate diff before ranking, truncating, or chunking it, including removed lines, displayed unchanged diff context, and hunk labels. For Markdown, the local scan expands context to recover enclosing fences, tracking old and new versions separately. This expanded scan does not change the context budget sent to Ollama. Generated, binary, and oversized exclusions apply independently of sensitive-pattern checks.

### Built-In Matcher Scope

The matcher checks credential-like assignments and provider-token or private-key signatures. Signature checks take precedence over assignment exemptions. Generic assignment matching uses a 12-character prefix threshold over its recognized value characters. The matching implementation is in `scan_sensitive_content` in [`git-ai.sh`](../git-ai.sh).

- Python and JavaScript/TypeScript source get syntax-aware handling for unquoted function calls, environment lookups, variable references, and member references. Logical expressions are examined for literal fallbacks. Quoted ternary labels are distinguished from assignments.
- For `.md` and `.mdx`, source syntax rules apply inside labeled Python, JavaScript, and TypeScript fences, including extension names such as `py`, `js`, `jsx`, `ts`, `tsx`, `mjs`, `cjs`, `mts`, and `cts`. Backtick and tilde fences are supported. Prose, unlabeled blocks, shell and configuration blocks, and unknown file types retain conservative matching.
- Narrow exemptions apply to individual values. Complete quoted source literals can qualify as known placeholder labels made from the allowed vocabulary, a credential noun, and a synthetic marker or leading test marker. The matcher also recognizes the exact OAuth example label `client-secret`. Public HMAC/signing namespaces must be dotted and end with the variable name without `_SALT` at a component boundary, treating hyphens and underscores as equivalent. Arbitrary values, concatenations, and separate credentials on the same line remain subject to matching.
- Conventional Python and JavaScript/TypeScript test paths recognize bounded fixture labels for provider tokens, test passwords, and password lifecycle examples. These rules apply to qualifying source under `test/`, `tests/`, and `__tests__/`, Python `test_*.py` and `*_test.py` variants including `.pyi`, and JavaScript/TypeScript `.test` and `.spec` files. For a rename, both paths must qualify for the test exemption. Other credentials in a test file remain subject to matching. Test fixture rules do not apply to Markdown fences. The [matcher regression suite](../tests/secret-scanning.sh) covers accepted labels and neighboring cases that must remain protected.

## Overrides

| Mode or flag | Gitleaks commit guard | AI diff protection |
| --- | --- | --- |
| Default | A finding blocks a regular commit. | Findings or built-in matches activate safe mode. |
| `--dry-run` | A finding warns and allows a preview. A scanner failure stops the run. | Safe mode still applies. |
| `--allow-secret-commit` | A finding allows the run to proceed to generation and commit. A scanner failure still stops the run. | Safe mode still applies. |
| `--force-diff` | The scanner still runs and a finding blocks a regular commit unless separately allowed. | Detailed sensitive context becomes eligible for transmission. |
| `--force` | Skip the scan. The executable is still required for dependency validation. | Disable safe mode and allow detailed sensitive context through the remaining eligibility and size limits. |

Combining `--allow-secret-commit` and `--force-diff` still runs the scanner and requires a usable result. See [CLI Usage](usage.md) for the independent staging, commit, and push controls.

## Debug Output

`--debug` can display repository paths, Git metadata, configuration, model requests and responses, validation reasons, and the full staged diff. Safe mode omits the raw staged diff from debug output, while requests, responses, and metadata can still contain private details. When `--force-diff` or `--force` disables that protection, debug can also print sensitive diffs. Keep traces private and sanitize them before sharing. Scanner output follows the separate [report-handling rules](#gitleaks-commit-guard).
