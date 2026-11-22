# Security Policy

[Documentation index](../README.md#documentation)

`git-auto-commit-ollama` is a Bash CLI that reads Git diffs, generates commit messages through a configured Ollama endpoint, and can run `git commit` and `git push`. Because the tool interacts with Git state, staged changes, secret scanning, and network endpoints, security reports are prioritized according to their impact on repository confidentiality, integrity, and user control.

## Table of Contents

- [Supported Versions](#supported-versions)
- [Safe Usage](#safe-usage)
- [Reporting a Vulnerability](#reporting-a-vulnerability)
- [What to Include](#what-to-include)
- [Scope](#scope)
- [Out of Scope](#out-of-scope)
- [Disclosure Process](#disclosure-process)
- [Security Controls](#security-controls)
  - [Data Sent to Ollama](#data-sent-to-ollama)
  - [Gitleaks Commit Guard](#gitleaks-commit-guard)
    - [Scanner Configuration](#scanner-configuration)
  - [Safe Mode](#safe-mode)
    - [Built-In Matcher Scope](#built-in-matcher-scope)
  - [Overrides](#overrides)
  - [Debug Output](#debug-output)
- [Security Design Notes](#security-design-notes)

## Supported Versions

Security support follows the `main` branch and the latest `git-ai.sh` revision. The `VERSION` value in the script identifies the CLI version; it does not guarantee security backports for every older minor release.

| Version or branch | Supported | Notes |
| --- | --- | --- |
| `main` | Yes | Primary target for security patches. |
| Older commits or copies | Not guaranteed | Update to `main`; reports remain useful when the issue also affects the latest version. |
| Modified local forks | Best effort | Include a non-sensitive diff when the issue occurs only in the fork. |

Update this table if official release tags or maintenance branches are added.

## Safe Usage

Use a local or trusted network Ollama endpoint and review both configured hosts. Secret detection is best effort. Keep credentials out of staged changes, use repository ignore rules for local secrets, and review the index before using `--no-stage`. [Host resolution](../docs/configuration.md#ollama-host-resolution) · [Staging and commit review](../docs/usage.md#staging-and-commit-review)

## Reporting a Vulnerability

Report vulnerabilities privately through GitHub Security Advisories:

```text
https://github.com/aibersemi/git-auto-commit-ollama/security/advisories/new
```

If private vulnerability reporting is not available, do not open a public issue containing exploit details, secrets, or a full proof of concept. Open a minimal public issue requesting a private security contact, or contact the maintainer through an available private organization channel.

Use public issues only for non-security bugs, such as documentation typos, help output errors, or usability problems without confidentiality, integrity, or unauthorized-access impact.

## What to Include

Include the following information to help triage:

- The script version from `git-ai --version`.
- The tested commit hash or branch.
- The operating system, shell, and versions of `git`, `curl`, `jq`, and `flock`.
- Whether the `gitleaks` and `ollama` CLIs are available.
- Non-sensitive configuration from `git-ai.conf`.
- The command that was run.
- Reproduction steps in a temporary repository.
- A clear description of the security impact.
- Actual and expected behavior.
- Sanitized logs.

Do not include:

- Valid secrets, tokens, passwords, private keys, cookies, sessions, or internal credentials.
- Private repository diffs that must not be shared.
- Sensitive internal URLs, hostnames, usernames, or production paths.
- Payloads that destroy data or perform destructive actions.

Use the [isolated runtime smoke test](../docs/verification.md#isolated-runtime-smoke-test) to prepare a safe reproduction.

## Scope

The following reports are in scope:

- Detailed diffs or sensitive data are sent to Ollama when safe mode should be active.
- The Gitleaks integration fails to block a reported token, private key, password, or credential in staged additions.
- Options such as `--force`, `--force-diff`, or `--allow-secret-commit` become active without an explicit user action.
- Command injection, argument injection, or unexpected shell evaluation is triggered by a file name, diff, branch, remote, configuration value at use time, or model output.
- `--dry-run` permanently changes the original index contents, refs, or stored Git objects, creates a commit, or pushes. Automatic staging with `--no-stage` and pushing with `--no-push` are also in scope.
- A race condition or lock bypass allows concurrent `git-ai` processes to corrupt Git state in the same repository.
- Temporary file, lock file, or cleanup handling can damage files outside the intended area.
- Ollama fallback-host resolution or service-environment reading sends data to an endpoint that was not configured.
- Debug logs, errors, or summaries expose secrets from staged changes.
- Configuration validation regressions silently change security behavior.

## Out of Scope

The following are generally not treated as project vulnerabilities:

- Commit message quality, model hallucinations, or inaccurate commit subjects.
- Behavior explicitly authorized by the user and within the documented bounds of `--force`, `--force-diff`, `--allow-secret-commit`, or `--no-verify`. Behavior beyond those bounds remains in scope. [Security overrides](#overrides) · [Git hook behavior](../docs/usage.md#push-behavior-and-hooks)
- Vulnerabilities in Git, Ollama, curl, jq, flock, gitleaks, the shell, the operating system, or third-party AI models.
- A workstation, repository, or user account already controlled by an attacker before `git-ai` runs.
- Commands explicitly written in `git-ai.conf`, because the file is intentionally sourced as trusted shell code. Bypassing write permissions or unexpectedly re-evaluating configuration values remains in scope.
- Malicious Git hooks in a repository when the user chooses to run hooks.
- Data leakage by a user-configured Ollama endpoint outside this project's control.
- Social engineering, phishing, spam, brute force, or attacks on maintainer accounts.
- Denial of service that only consumes local time on very large input without confidentiality or integrity impact.
- Bounty requests. This project does not currently run a bounty program.

When uncertain, report privately. The maintainer will classify the report as a security issue, ordinary bug, or hardening request.

## Disclosure Process

Response targets:

| Stage | Target |
| --- | --- |
| Acknowledgement | Within 7 calendar days. |
| Initial triage | Within 14 calendar days. |
| Status update | At least every 14 days after triage while a valid issue remains unresolved. |
| Fix target | Based on severity and complexity, with high-impact issues prioritized. |

Handling process:

1. The maintainer receives the private report and acknowledges it.
2. The maintainer attempts to reproduce the issue on `main`.
3. The maintainer determines severity, scope, and affected versions.
4. A patch is prepared in a private branch or fork when necessary.
5. The reporter is asked to verify the fix when possible.
6. After a fix is available, the maintainer publishes an advisory or release note with enough detail to support mitigation.

Do not disclose exploit details before a fix is available or before agreeing on disclosure timing with the maintainer.

## Security Controls

### Data Sent to Ollama

Ollama preflight checks endpoint availability and model readiness before staging or scanning and sends no repository diff. Analysis and final generation can send file names, statuses, Git statistics and summaries, eligible complete diffs, excerpts, per-file summaries, and rejected message candidates during corrections. A preview uses the same network integration as a regular run. [Host resolution](../docs/configuration.md#ollama-host-resolution)

File paths, diffs, documentation including `AGENTS.md`, analysis responses, and prior commit candidates are untrusted input to prompts. Instructions tell the model to treat them as data. That reduces prompt-injection risk without verifying the factual accuracy of the generated message. Review the final result against the staged changes.

### Gitleaks Commit Guard

Gitleaks scans staged additions before AI context collection. It uses `gitleaks git --pre-commit --staged --redact` and writes a JSON report to a private temporary directory. The CLI accepts exit code `0` with an empty report or exit code `10` with findings. Displayed findings contain only the file, line, and rule ID, limited to 20 entries plus a count of additional findings. The report is removed after processing. Raw scanner logs are suppressed even in debug mode.

A missing scanner, unsupported flags, execution errors, invalid configuration, and missing, invalid, or inconsistent reports stop processing before generation, commit, or push. See the override table for how each mode handles a successful scan with findings. [Overrides](#overrides)

#### Scanner Configuration

The scanner runs from the repository root, even when the CLI starts in a subdirectory. Configuration priority is `GITLEAKS_CONFIG` (file), `GITLEAKS_CONFIG_TOML` (inline TOML), root `.gitleaks.toml`, then default Gitleaks rules. `GITLEAKS_CONFIG` and relative Git path overrides such as `GIT_INDEX_FILE` keep their meaning relative to the caller. Configuration includes and `.gitleaksignore` resolve from the root. Nested policy files do not take over the scan. An invalid selected configuration stops the scan. Debug output identifies the configuration source without printing inline TOML.

Configuration and ignore files come from the working tree, while scanned additions come from the index. Review custom rules, `.gitleaksignore`, and `gitleaks:allow` annotations because they affect blocking. To extend the default rules in a repository-specific configuration, include the following in the root `.gitleaks.toml`.

```toml
[extend]
useDefault = true
```

Scanner exclusions are independent of the built-in matcher. Default Gitleaks rules may miss generic passwords, so use reviewed custom rules when those patterns must block commits.

### Safe Mode

Gitleaks finding paths and matches from the built-in diff matcher activate safe mode. Safe mode removes detailed diffs and diff-derived terms from the final prompt. Metadata can still be sent, and per-file requests can send complete or sampled diffs from files that pass screening. Flagged files are excluded from this analysis. The matcher alone never blocks a commit.

The CLI checks the whole candidate diff before ranking, truncating, or sampling it, including removed lines, displayed unchanged diff context, and hunk labels. For Markdown, the local scan expands context to recover enclosing fences, tracking old and new versions separately. This expanded scan does not change the context budget sent to Ollama. Generated, binary, and oversized exclusions apply independently of sensitive-pattern checks.

#### Built-In Matcher Scope

The matcher checks credential-like assignments and provider-token or private-key signatures. Signature checks take precedence over assignment exemptions. Generic assignment matching uses a 12-character prefix threshold over its recognized value characters. The matching implementation is in `scan_sensitive_content` in [`git-ai.sh`](../git-ai.sh).

- Python and JavaScript/TypeScript source get syntax-aware handling for unquoted function calls, environment lookups, variable references, and member references. Logical expressions are examined for literal fallbacks. Quoted ternary labels are distinguished from assignments.
- For `.md` and `.mdx`, source syntax rules apply inside labeled Python, JavaScript, and TypeScript fences, including extension names such as `py`, `js`, `jsx`, `ts`, `tsx`, `mjs`, `cjs`, `mts`, and `cts`. Backtick and tilde fences are supported. Prose, unlabeled blocks, shell and configuration blocks, and unknown file types retain conservative matching.
- Narrow exemptions apply to individual values. Complete quoted source literals can qualify as known placeholder labels made from the allowed vocabulary, a credential noun, and a synthetic marker or leading test marker. The matcher also recognizes the exact OAuth example label `client-secret`. Public HMAC/signing namespaces must be dotted and end with the variable name without `_SALT` at a component boundary, treating hyphens and underscores as equivalent. Arbitrary values, concatenations, and separate credentials on the same line remain subject to matching.
- Conventional Python and JavaScript/TypeScript test paths recognize bounded fixture labels for provider tokens, test passwords, and password lifecycle examples. These rules apply to qualifying source under `test/`, `tests/`, and `__tests__/`, Python `test_*.py` and `*_test.py` variants including `.pyi`, and JavaScript/TypeScript `.test` and `.spec` files. For a rename, both paths must qualify for the test exemption. Other credentials in a test file remain subject to matching. Test fixture rules do not apply to Markdown fences. The [matcher regression suite](../tests/secret-scanning.sh) covers accepted labels and neighboring cases that must remain protected.

### Overrides

| Mode or flag | Gitleaks commit guard | AI diff protection |
| --- | --- | --- |
| Default | A finding blocks a regular commit. | Findings or built-in matches activate safe mode. |
| `--dry-run` | A finding warns and allows a preview. | Safe mode still applies. |
| `--allow-secret-commit` | A finding allows the run to proceed to generation and commit. | Safe mode still applies. |
| `--force-diff` | The scanner still runs and a finding blocks a regular commit unless separately allowed. | Detailed sensitive context becomes eligible for transmission. |
| `--force` | Skip the scan. The executable is still required for dependency validation. | Disable safe mode and allow detailed sensitive context through the remaining eligibility and size limits. |

Modes that run Gitleaks require a usable result, including when `--allow-secret-commit` and `--force-diff` are combined. [Staging, commit, and push controls](../docs/usage.md)

### Debug Output

`--debug` can display repository paths, Git metadata, configuration, model requests and responses, validation reasons, and the full staged diff. Safe mode omits the raw staged diff from debug output, while requests, responses, and metadata can still contain private details. When `--force-diff` or `--force` disables that protection, debug can also print sensitive diffs. Keep traces private and sanitize them before sharing. Scanner output follows the separate [report-handling rules](#gitleaks-commit-guard).

## Security Design Notes

Preserve conservative defaults and explicit override boundaries when changing the security controls. Review endpoint selection, prompt input, and diagnostic output whenever a change touches repository data. Discuss new network calls explicitly before accepting them. [Security controls](#security-controls)

Keep tagged release validation read-only and grant release write access only to publication. See [Repository Automation](../docs/automation.md#releases) for the workflow and [Targeted Regression Checks](../docs/verification.md#targeted-regression-checks) for security verification.

See the [contribution checklist](CONTRIBUTING.md#checklist) before submitting a change.
