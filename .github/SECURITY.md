# Security Policy

`git-auto-commit-ollama` is a Bash CLI that reads Git diffs, generates commit messages through a configured Ollama endpoint, and can run `git commit` and `git push`. Because the tool interacts with Git state, staged changes, secret scanning, and network endpoints, security reports are prioritized according to their impact on repository confidentiality, integrity, and user control.

## Table of Contents

- [Supported Versions](#supported-versions)
- [Safe Usage](#safe-usage)
- [Reporting a Vulnerability](#reporting-a-vulnerability)
- [What to Include](#what-to-include)
- [Scope](#scope)
- [Out of Scope](#out-of-scope)
- [Disclosure Process](#disclosure-process)
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

Review the data sent to Ollama, the distinction between Gitleaks and safe mode, and the effects of each override in [Security Controls](../docs/security.md). The [CLI guide](../docs/usage.md) covers dry-run, staging, and hooks.

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
- Sensitive diff transmission and secret-scanner bypass explicitly authorized with `--force`, sensitive diff transmission explicitly authorized with `--force-diff`, commits explicitly authorized with `--allow-secret-commit`, or commit-hook bypass explicitly requested with `--no-verify`. Behavior beyond each override's documented boundary remains in scope.
- Vulnerabilities in Git, Ollama, curl, jq, flock, gitleaks, the shell, the operating system, or third-party AI models.
- A workstation, repository, or user account already controlled by an attacker before `git-ai` runs.
- Commands explicitly written in `git-ai.conf`, because the file is intentionally sourced as trusted shell code. Bypassing write permissions or unexpectedly re-evaluating configuration values remains in scope.
- A repository containing malicious Git hooks when the user chooses to run hooks. `--no-verify` skips `pre-commit` and `commit-msg` but does not disable `pre-push`.
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

## Security Design Notes

Preserve conservative defaults and explicit override boundaries when changing the [runtime security controls](../docs/security.md). Review endpoint selection, prompt input, and diagnostic output whenever a change touches repository data. Discuss new network calls explicitly before accepting them.

Keep tagged release validation read-only and grant release write access only to publication. See [Repository Automation](../docs/automation.md#releases) for the workflow and [Targeted Regression Checks](../docs/verification.md#targeted-regression-checks) for security verification.

See the [contribution checklist](CONTRIBUTING.md#checklist) before submitting a change.
