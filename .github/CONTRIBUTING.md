# Contributing

Thank you for contributing to `git-auto-commit-ollama`. These guidelines help keep changes focused, reviewable, and safe for a tool that directly operates on users' Git state.

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

- Bug fixes for staging, commits, pushes, repository locking, or Ollama integration.
- Improvements to secret detection, safe mode, and sensitive-data handling.
- Improvements to prompts, structured output, corrective retries, or subject validation.
- Performance improvements for per-file analysis and diff context collection.
- Usage, troubleshooting, configuration, and deployment documentation.
- Bash linting, CI validation, and test scenarios.

Discuss major changes in an issue before opening a pull request. Examples include changing the default model, adding a required dependency, changing the commit message format, or changing default push behavior.

## Before You Start

- Read the [documentation index](../README.md#documentation) and review the relevant technical guides.
- Follow the [installation prerequisites](../docs/installation.md#prerequisites). Keep the scanner interface and JSON reporting compatible with the version validated in [CI](../docs/automation.md#continuous-integration).
- Check existing issues and pull requests to avoid duplicate work.
- Keep each change focused on one problem.
- Follow the sensitive-data policy in [`SECURITY.md`](SECURITY.md).
- Preserve compatibility with both local and trusted-network Ollama usage.

## Code Standards

This project is a Bash CLI. Follow the existing style in `git-ai.sh`.

- Preserve `#!/usr/bin/env bash` and `set -euo pipefail`.
- Keep Bash linting clean using the [local verification commands](../docs/verification.md#local-checks).
- Quote variable expansions unless there is a clear Bash-specific reason not to.
- Prefer small functions with names that describe their behavior.
- Write all repository content in English, including comments, user-facing output, prompts, errors, documentation, templates, and configuration comments.
- Do not add a required dependency without updating `check_deps`, the README, this guide, and the installation prerequisites.
- When adding a CLI option, update `parse_args`, `show_help`, the README, the [CLI reference](../docs/usage.md#options), and relevant examples.
- When changing configuration, update `git-ai.conf`, configuration validation, the README, fallback defaults, and the [configuration reference](../docs/configuration.md).
- Avoid destructive changes to users' Git state. Add a dry-run, confirmation, or clear guard for risky behavior.
- Keep secret handling conservative. Do not weaken safe mode or the secret guard without a strong technical reason.

## Testing

Push and pull request CI runs basic checks. See [Continuous Integration](../docs/automation.md#continuous-integration) to run the regression suites on GitHub for behavior changes.

Follow [Verification](../docs/verification.md) for local commands, regression coverage, workflow checks, and the isolated runtime smoke test. For documentation-only changes, follow [Documentation Verification](../docs/verification.md#documentation-verification). Report which checks ran and why any applicable checks were skipped.

## Issue Guidelines

Follow the [Support Guide](SUPPORT.md) for bug reports and feature requests. Explain security, default-push, and CLI compatibility implications in feature proposals. Report vulnerabilities privately through the [Security Policy](SECURITY.md).

## Pull Request Guidelines

A typical contribution workflow is:

```bash
git checkout -b fix/short-description
# edit files
# run the validation relevant to the change
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

Keep pull requests small. If a change requires both a large refactor and a behavior change, split it into independently reviewable pull requests.

## Sensitive Changes

For vulnerabilities, threat-surface changes, or secret-handling changes, follow [`SECURITY.md`](SECURITY.md). Explain the security impact and additional testing in the pull request without exposing sensitive exploit details.

## Documentation

Update documented contracts when commands, dependencies, configuration, architecture, operations, or data handling change. Use the [documentation ownership map](../docs/architecture.md#documentation-ownership) to locate the primary guide, and follow the [repository writing rules](../AGENTS.md#documentation). Update the README index and incoming links when navigation changes.

## Checklist

Before submitting an issue or pull request, confirm:

- The change focuses on one problem.
- Applicable verification has been run and recorded.
- Runtime changes include isolated smoke test results or the reason the live test was skipped.
- Documentation is updated when behavior changed.
- Security-sensitive changes follow the Security Policy.
- Default changes include a clear rationale.
