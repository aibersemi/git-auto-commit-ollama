# Contributing

Thank you for contributing to `git-auto-commit-ollama`. These guidelines help
keep changes focused, reviewable, and safe for a tool that directly operates on
users' Git state.

## Table of Contents

- [Contribution Types](#contribution-types)
- [Before You Start](#before-you-start)
- [Code Standards](#code-standards)
- [Testing](#testing)
- [Issue Guidelines](#issue-guidelines)
- [Pull Request Guidelines](#pull-request-guidelines)
- [Sensitive Changes](#sensitive-changes)
- [Documentation](#documentation)
- [Checklist](#checklist)
- [Security Policy](SECURITY.md)

## Contribution Types

Useful contributions include:

- Bug fixes for staging, commits, pushes, repository locking, or Ollama
  integration.
- Improvements to secret detection, safe mode, and sensitive-data handling.
- Improvements to prompts, structured output, corrective retries, or subject validation.
- Performance improvements for per-file analysis and diff context collection.
- Usage, troubleshooting, configuration, and deployment documentation.
- Bash linting, CI validation, and test scenarios.

Discuss major changes in an issue before opening a pull request. Examples
include changing the default model, adding a required dependency, changing the
commit message format, or changing default push behavior.

## Before You Start

- Read the [`README.md`](../README.md) to understand the workflow and CLI
  options.
- Follow the prerequisites and installation instructions in the README instead
  of duplicating them here. Gitleaks is a required runtime dependency; keep its
  supported CLI interface and JSON reporting compatible with the validated
  version in the README and CI.
- Check existing issues and pull requests to avoid duplicate work.
- Keep each change focused on one problem.
- Follow the sensitive-data policy in [`SECURITY.md`](SECURITY.md).
- Preserve compatibility with both local and trusted-network Ollama usage.

## Code Standards

This project is a Bash CLI. Follow the existing style in `git-ai.sh`.

- Preserve `#!/usr/bin/env bash` and `set -euo pipefail`.
- Keep Bash linting clean; the primary validation commands are in the README.
- Quote variable expansions unless there is a clear Bash-specific reason not
  to.
- Prefer small functions with names that describe their behavior.
- Write all repository content in English, including comments, user-facing
  output, prompts, errors, documentation, templates, and configuration
  comments.
- Do not add a required dependency without updating `check_deps`, the README,
  and this guide.
- When adding a CLI option, update `parse_args`, `show_help`, the README, and
  relevant examples.
- When changing configuration, update `git-ai.conf`, configuration validation,
  the README, and fallback defaults.
- Avoid destructive changes to users' Git state. Add a dry-run, confirmation,
  or clear guard for risky behavior.
- Keep secret handling conservative. Do not weaken safe mode or the secret
  guard without a strong technical reason.

## Testing

Run the basic validation from
[`README.md#development`](../README.md#development) before opening a pull
request.

For runtime changes involving staging, prompts, commits, or pushes, test in a
temporary repository. Do not use a primary working repository for experiments
that could create a commit.

```bash
tmpdir=$(mktemp -d)
git init "$tmpdir"
cd "$tmpdir"
git config user.name "git-ai test"
git config user.email "git-ai-test@example.invalid"
printf 'hello\n' > sample.txt
/path/to/git-auto-commit-ollama/git-ai.sh --dry-run --no-push --no-banner
```

The smoke test requires an active Ollama endpoint and an available model.
Report it as not run when that environment is unavailable.

For changes to commit reference selection or prompts, run the Markdown
reference regression suite described in
[`README.md#development`](../README.md#development). Keep fixtures isolated,
use mock responses for deterministic assertions, and verify both selected
reference content and preservation of the original index and refs. Include
fallback, bounded excerpts, safe mode, analysis failures, and both CLI output
modes. Include documentation-only security/API paths, tests-only, CI-only,
templates/stylesheets, and combined runtime/Markdown scenarios representing
recovery flows and commit generation. Verify full-diff scoring, ranked late
hunks, Unicode bounds, reserved runtime context, and rejection of supporting
themes in the subject or first bullet. Cover visible quality-rejection reasons
and corrective retries for
plain text, structured JSON, and plain text returned to a structured request.
Include runtime rules about test inputs alongside real test-fixture maintenance, exact rejection locations, and bounded unchanged source context. Verify success after two invalid responses, stopping after three invalid responses, mixed request/validation failures, and request exhaustion. Failure tests must assert a nonzero exit, bounded API calls, unchanged index/refs, released locks, and no attempted commit or push. Keep retry-delay mocks scoped to isolated CLI tests.
Follow the README runtime check when Ollama is available; do not use
real commits or pushes for validation.

If a change affects secret detection, test at least:

- Run `bash tests/secret-scanning.sh` with the syntax and lint checks listed
  in [`README.md#development`](../README.md#development). This suite uses
  isolated Git indexes and mocked Ollama/Gitleaks responses.
- Run `bash tests/gitleaks-integration.sh` with the installed Gitleaks binary.
  This suite verifies actual staged scanning and isolated-index behavior
  without Ollama, commits, or pushes.
- Gitleaks findings must block commits independently of built-in exemptions.
  Built-in-only matches must protect AI context without blocking commits.
- Missing Gitleaks, execution errors, invalid configuration, and invalid or
  inconsistent JSON reports must stop generation even with preview or finding
  overrides. Reports and scanner logs must not expose credential values.
- Gitleaks-only findings must be excluded from all AI context unless an
  explicit diff override is active.
- Generated values, environment lookups, and variable/member references in
  Python and JavaScript/TypeScript without enabling safe mode.
- Quoted literals, unquoted configuration values, and unknown file types
  without granting expression exemptions.
- A placeholder secret that should be allowed.
- Predictable provider-token and password fixtures in conventional test source paths, while production/configuration paths, arbitrary suffixes, concatenations, source-to-test renames, and other credentials in the same tests remain protected. See the bounded fixture rules in [`README.md#security`](../README.md#security).
- Public HMAC/signing namespace salts without warnings, while arbitrary salt literals, configuration values, concatenations, and credentials on the same line remain protected.
- Multiple candidates on one line, ensuring placeholders cannot hide another
  literal or a provider/private-key signature.
- A realistic fake token that should be blocked.
- Removed and unchanged context lines that remain protected from AI context
  without blocking harmless added lines.
- Preview mode when a secret is detected.
- The secret-commit override if its behavior changed.

Assemble synthetic credential-like values at runtime rather than storing
complete token/key markers in test source. Reports must never contain values,
and tests must preserve the original index and refs without commits or pushes.

If a change affects Ollama integration, test:

- The primary `DEFAULT_OLLAMA_HOST`.
- The fallback host when configured.
- A missing model with and without `--no-pull`.
- `--no-structured` when structured-output logic changed.

If a change affects per-file analysis performance, test one file, the default
selection of six files, a larger selection, and local-summary fallback for
an invalid or incomplete response. Confirm that every request contains one file
even when a legacy batch-size value exceeds `1`. Confirm that generated or
ephemeral paths, binary files, and oversized staged blobs are excluded from
per-file AI requests without changing dry-run Git state.

If a change affects adaptive parallelism, test `auto` and numeric overrides for
both local and AI jobs. Cover local systemd detection, a remote Ollama capacity
hint, conservative fallback, deterministic result ordering, and worker caps
smaller and larger than the number of ready jobs. Measure overlapping analysis
requests and verify worker limits and loading rows using the checks in
[`README.md#development`](../README.md#development). Gitleaks scanning must
finish before applying the commit policy and collecting AI context. Effective AI capacity `1` must call
the analysis function in the foreground; only the renderer may run in the
background.

For analysis-progress changes, use delayed mock responses and a simulated
clock to check progress before results arrive, queued files, completion out
of order, and local fallbacks. Assert that each numbered completion is printed
exactly once and the final file count remains visible. Follow the terminal
dry-run checks and estimated progress behavior documented in the README.

## Issue Guidelines

When reporting a bug, include:

- The script version from `git-ai --version`.
- The operating system and shell.
- Relevant `git`, `jq`, `curl`, and `shellcheck` versions.
- Non-sensitive configuration from `git-ai.conf`.
- The command that was run.
- Actual and expected behavior.
- Sanitized logs.

For a feature request, explain:

- The problem to solve.
- The current workflow.
- The proposed behavior.
- Security, default-push, and CLI compatibility implications.

Do not use a public issue for security reports. Follow
[`SECURITY.md`](SECURITY.md). Sanitize logs and configuration before publishing
ordinary bug reports.

## Pull Request Guidelines

A typical contribution workflow is:

```bash
git checkout -b fix/short-description
# edit files
# run validation from the README Development section
git status
git commit
git push -u origin fix/short-description
```

A pull request should contain:

- A summary of the problem and solution.
- A list of the main files changed.
- Results from the validation commands that were run.
- Compatibility notes when options, configuration, or default behavior changed.
- Short screenshots or logs only when useful and sanitized.

Keep pull requests small. If a change requires both a large refactor and a
behavior change, split it into independently reviewable pull requests.

## Sensitive Changes

For vulnerabilities, threat-surface changes, or secret-handling changes, follow
[`SECURITY.md`](SECURITY.md). Explain the security impact and additional
testing in the pull request without exposing sensitive exploit details.

## Documentation

Update documentation when a change affects:

- CLI options.
- Configuration variables.
- Dependencies.
- Default commit or push behavior.
- Secret handling.
- Installation, removal, or troubleshooting.

Files that commonly require updates include:

- [`README.md`](../README.md)
- [`git-ai.conf`](../git-ai.conf)
- Help output in `show_help`
- Relevant examples in this guide

## Checklist

Before submitting an issue or pull request, confirm:

- The change focuses on one problem.
- The basic README validation has been run.
- Additional smoke testing is documented when runtime behavior changed.
- Documentation is updated when behavior changed.
- Security-sensitive changes follow the Security Policy.
- Default changes include a clear rationale.
