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
- Improvements to prompts, structured output, fallback commit subjects, or
  subject validation.
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
  of duplicating them here.
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

If a change affects secret detection, test at least:

- A placeholder secret that should be allowed.
- A realistic fake token that should be blocked.
- Preview mode when a secret is detected.
- The secret-commit override if its behavior changed.

If a change affects Ollama integration, test:

- The primary `DEFAULT_OLLAMA_HOST`.
- The fallback host when configured.
- A missing model with and without `--no-pull`.
- `--no-structured` when structured-output logic changed.

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
