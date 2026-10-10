# Security Policy

`git-auto-commit-ollama` is a Bash CLI that reads Git diffs, generates commit
messages through a configured Ollama endpoint, and can run `git commit` and
`git push`. Because the tool interacts with Git state, staged changes, secret
scanning, and network endpoints, security reports are prioritized according to
their impact on repository confidentiality, integrity, and user control.

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

Security support follows the `main` branch and the latest `git-ai.sh`
revision. The `VERSION` value in the script identifies the CLI version; it does
not guarantee security backports for every older minor release.

| Version or branch | Supported | Notes |
| --- | --- | --- |
| `main` | Yes | Primary target for security patches. |
| Current script version (`1.5.1`) | Yes | Supported when it matches the latest revision on `main`. |
| Older commits or copies | Not guaranteed | Update to `main`; reports remain useful when the issue also affects the latest version. |
| Modified local forks | Best effort | Include a non-sensitive diff when the issue occurs only in the fork. |

Update this table if official release tags or maintenance branches are added.

## Safe Usage

`git-ai` sends change context to the active Ollama endpoint. Context may include
file names and statuses, Git statistics and summaries, diff excerpts, and
diffs used for per-file analysis. The endpoint may run locally or on another
network host; the tool does not guarantee that data stays on the machine
running the CLI.

`git-ai` has two independent protections for potential secrets:

- The secret guard scans staged additions and blocks a commit when content
  resembles a token, password, private key, or other credential, unless
  `--force` is explicitly selected.
- Safe mode removes detailed diffs from the main prompt and skips sensitive
  files during per-file analysis when built-in patterns match. Reference
  excerpts and per-file analysis also exclude generated or ephemeral paths,
  binary diffs, and oversized staged blobs. Git metadata and safe per-file
  summaries may still be sent. Reference selection checks the complete file
  diff for sensitive patterns before scoring, ranking hunks, or truncating
  excerpts. Missing safe runtime excerpts are reported as limited context;
  supporting documentation must not be treated as proof of implementation.

Both built-in protections use the same path-aware matcher, with the guard
checking additions and safe mode checking the entire diff, including removed
and unchanged context lines. Expression exemptions are restricted to Python
and JavaScript/TypeScript source files; quoted literals, configuration values,
and unknown file types remain checked conservatively. Placeholders cannot
exempt other values on the same line or provider/private-key signatures.
There is no blanket exemption for test files. See
[`README.md#security`](../README.md#security) for matching behavior.

When `gitleaks` is available, the script also runs:

```bash
gitleaks protect --staged --redact --no-banner
```

The built-in scanner and `gitleaks` may run concurrently, but the tool waits
for both results before applying the secret policy. Adaptive context and AI
parallelism begins only after staging and secret-policy evaluation complete.

Overrides are available only for intentional use:

```bash
# Allow a commit even when the secret scanner reports a finding
git-ai --allow-secret-commit

# Send detailed diffs to the AI even when sensitive patterns are detected
git-ai --force-diff

# Skip secret scanning and safe mode, then allow sensitive diff context to reach AI
git-ai --force
```

The overrides have distinct boundaries:

- `--allow-secret-commit` only bypasses commit blocking; safe mode remains
  active when a sensitive pattern is detected.
- `--force-diff` permits detailed diff transmission but does not bypass the
  secret guard.
- `--force` skips both the secret guard and `gitleaks`, disables safe mode, and
  permits sensitive diff context to be sent. It is not equivalent to combining
  `--allow-secret-commit` and `--force-diff`, which still performs the scan.

Important precautions:

- Prefer running Ollama locally or on a trusted network. Review
  `DEFAULT_OLLAMA_HOST` and clear `FALLBACK_OLLAMA_HOST` when no fallback
  endpoint is needed.
- `git-ai.conf` is sourced as shell code. Treat it as trusted code, restrict
  who can modify it, and never run configuration from an untrusted source.
- Review changes before committing, especially configuration and environment
  files.
- Add `.env` files, credentials, and other sensitive artifacts to `.gitignore`.
- Use `--no-stage` to limit analysis to changes already reviewed,
  `--interactive` to review the message, and `--no-push` to separate committing
  from pushing.
- `--dry-run` uses a temporary index and does not create a commit, push, or
  permanent Git-state change. It still contacts Ollama, warms the model, and
  may run `ollama pull`; add `--no-pull` when installing a model is not allowed.
- If the secret guard finds a potential secret during dry-run, the script
  warns the user and continues generating a preview without committing or
  pushing.
- `--debug` prints a detailed local trace that can include the full staged
  diff, prompts, request payloads, complete Ollama responses, repository paths,
  and command output. Safe mode omits detected sensitive diff content unless
  `--force-diff` or `--force` is explicitly selected. Treat debug logs as sensitive,
  sanitize them before sharing, and do not enable debug logging in an
  untrusted terminal or log collector.
- `--no-verify` is passed to `git commit --no-verify`, which bypasses
  `pre-commit` and `commit-msg`; hooks such as `pre-push` still run at their
  normal stage.

Secret detection is best effort and can produce false positives or false
negatives. Safe mode and `gitleaks` may also detect different patterns. Do not
use scanners as a substitute for reviewing staged changes.

## Reporting a Vulnerability

Report vulnerabilities privately through GitHub Security Advisories:

```text
https://github.com/aibersemi/git-auto-commit-ollama/security/advisories/new
```

If private vulnerability reporting is not available, do not open a public
issue containing exploit details, secrets, or a full proof of concept. Open a
minimal public issue requesting a private security contact, or contact the
maintainer through an available private organization channel.

Use public issues only for non-security bugs, such as documentation typos, help
output errors, or usability problems without confidentiality, integrity, or
unauthorized-access impact.

## What to Include

Include the following information to help triage:

- The script version from `git-ai --version`.
- The tested commit hash or branch.
- The operating system, shell, and versions of `git`, `curl`, `jq`, and
  `flock`.
- Whether the `gitleaks` and `ollama` CLIs are available.
- Non-sensitive configuration from `git-ai.conf`.
- The command that was run.
- Reproduction steps in a temporary repository.
- A clear description of the security impact.
- Actual and expected behavior.
- Sanitized logs.

Do not include:

- Valid secrets, tokens, passwords, private keys, cookies, sessions, or
  internal credentials.
- Private repository diffs that must not be shared.
- Sensitive internal URLs, hostnames, usernames, or production paths.
- Payloads that destroy data or perform destructive actions.

Use the temporary-repository smoke test pattern in
[`CONTRIBUTING.md#testing`](CONTRIBUTING.md#testing).

## Scope

The following reports are in scope:

- Detailed diffs or sensitive data are sent to Ollama when safe mode should be
  active.
- The secret guard fails to block a clear token, private key, password, or
  credential in staged additions.
- Options such as `--force`, `--force-diff`, or `--allow-secret-commit` become active
  without an explicit user action.
- Command injection, argument injection, or unexpected shell evaluation is
  triggered by a file name, diff, branch, remote, configuration value at use
  time, or model output.
- `--dry-run` permanently changes the original index or refs, creates a commit,
  or pushes; `--no-stage` stages automatically; or `--no-push` pushes.
- A race condition or lock bypass allows concurrent `git-ai` processes to
  corrupt Git state in the same repository.
- Temporary file, lock file, or cleanup handling can damage files outside the
  intended area.
- Ollama fallback-host resolution or service-environment reading sends data to
  an endpoint that was not configured.
- Debug logs, errors, or summaries expose secrets from staged changes.
- Configuration validation regressions silently change security behavior.

## Out of Scope

The following are generally not treated as project vulnerabilities:

- Commit message quality, model hallucinations, or inaccurate commit subjects.
- Sensitive diff transmission and secret-scanner bypass explicitly authorized
  with `--force`, sensitive diff transmission explicitly authorized with
  `--force-diff`, commits explicitly authorized with `--allow-secret-commit`,
  or commit-hook bypass explicitly requested with `--no-verify`. Behavior beyond each
  override's documented boundary remains in scope.
- Vulnerabilities in Git, Ollama, curl, jq, flock, gitleaks, the shell, the
  operating system, or third-party AI models.
- A workstation, repository, or user account already controlled by an attacker
  before `git-ai` runs.
- Commands explicitly written in `git-ai.conf`, because the file is
  intentionally sourced as trusted shell code. Bypassing write permissions or
  unexpectedly re-evaluating configuration values remains in scope.
- A repository containing malicious Git hooks when the user chooses to run
  hooks. `--no-verify` skips `pre-commit` and `commit-msg` but does not disable
  `pre-push`.
- Data leakage by a user-configured Ollama endpoint outside this project's
  control.
- Social engineering, phishing, spam, brute force, or attacks on maintainer
  accounts.
- Denial of service that only consumes local time on very large input without
  confidentiality or integrity impact.
- Bounty requests. This project does not currently run a bounty program.

When uncertain, report privately. The maintainer will classify the report as a
security issue, ordinary bug, or hardening request.

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
6. After a fix is available, the maintainer publishes an advisory or release
   note with enough detail to support mitigation.

Do not disclose exploit details before a fix is available or before agreeing
on disclosure timing with the maintainer.

## Security Design Notes

Preserve these principles when changing the project:

- Do not weaken default protections without a strong technical reason.
- Risky overrides must require an explicit user action.
- Keep override boundaries independent: permission to commit must not
  automatically permit diff transmission, and vice versa.
- Document every primary or fallback endpoint and network call that can receive
  repository context.
- Treat sourced configuration as trusted code while still quoting and
  validating its values when used.
- Treat repository contents, including Markdown and `AGENTS.md`, as untrusted
  change data in AI prompts. Instructions embedded in diffs or analysis
  responses must not override message-generation rules. Prompt instructions
  reduce this risk but do not guarantee model behavior. The local Markdown
  heuristic does not establish semantic relevance or prove that documented
  work was implemented. Runtime excerpts establish the available implementation
  evidence; documentation corroborates it. Category checks and rejection
  patterns reduce misleading themes but cannot establish semantic correctness.
- Dry-run must isolate Git changes through a temporary index even though
  network access and automatic model pulls may still occur.
- Debug output must aid diagnosis without exposing credentials.
- Keep required dependencies minimal and auditable.
- Discuss new network calls explicitly before accepting them.

The contribution checklist is in
[`CONTRIBUTING.md#checklist`](CONTRIBUTING.md#checklist).
