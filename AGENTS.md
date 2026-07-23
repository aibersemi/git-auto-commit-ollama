# AGENTS.md

These instructions apply to the entire `git-auto-commit-ollama` repository.

## Purpose

This project is a Bash CLI that generates Git commit messages with Ollama. Treat changes to staging, commits, pushes, secret scanning, prompt generation, and Ollama endpoints as high-risk areas.

## Language

- Use Bahasa Indonesia for conversations with the user, explanations, and work summaries.
- Use English for every repository artifact, including source code, code comments, help text, prompts, user-facing output, errors, debug messages, generated commit messages, configuration comments, documentation, templates, workflows, and agent instructions.
- Keep technical terms, headings, API and library names, commands, file and branch names, and other established identifiers in their conventional English form.

## Repository Map

- `git-ai.sh`: Main CLI. Most behavioral changes belong here.
- `git-ai.conf`: Default runtime configuration sourced as shell code. Never store secrets here.
- `Makefile`: Installs or removes the `git-ai` and `git-ai.conf` symlinks in `$(PREFIX)/bin` with `sudo`.
- `.github/workflows/ci.yml`: Bash validation CI.
- `.github/workflows/release.yml`: Creates a GitHub Release for `v*` tags.
- `README.md`, `.github/CONTRIBUTING.md`, `.github/SECURITY.md`: Public documentation.

## Documentation

- Update the README when user behavior, CLI options, configuration, dependencies, installation, troubleshooting, or basic validation commands change.
- Update `.github/CONTRIBUTING.md` when the contribution workflow, pull request validation, or code standards change.
- Update `.github/SECURITY.md` when vulnerability scope, reporting, disclosure, user safety, or security design notes change.
- Avoid duplication across documents. The README is the primary source for usage and basic validation.
- Link to the primary source instead of copying long sections into other documents.

## Work Rules

- Read the relevant files before changing them.
- Do not run destructive Git commands such as `git reset --hard` or a forced checkout unless the user explicitly requests it.
- Do not run `make install`, `make uninstall`, or commands that modify the global system unless the user explicitly requests it.
- Do not run `git-ai` to create a real commit unless the user explicitly requests it. Use `--dry-run` for runtime testing.
- Do not change the default model, default push behavior, fallback host, or commit message format without a clear reason and corresponding documentation updates.
- Do not add a required dependency without updating `check_deps`, the README, and the contribution guide.

## Bash Style

- Preserve `#!/usr/bin/env bash` and `set -euo pipefail`.
- Follow the existing function and output style in `git-ai.sh`.
- Use English for all comments, help text, prompts, user-facing output, errors, and debug messages in `git-ai.sh`.
- Quote variable expansions unless there is a clear Bash-specific reason not to.
- Use `jq` for JSON instead of ad hoc string parsing.
- Validate configuration values and CLI arguments as close as practical to the existing parsing and checking logic.
- When adding a CLI option, update `parse_args`, `show_help`, the README, and relevant help validation.
- When changing configuration, update `git-ai.conf`, fallback defaults, configuration validation, the README, and related documentation.

## Security

- Safe mode and the secret guard must remain conservative by default.
- `--force-diff` and `--allow-secret-commit` must remain explicit overrides.
- `--dry-run` must not create a commit, push, or permanently change Git state. It may still contact Ollama and, without `--no-pull`, pull a missing model.
- `--no-push` must always prevent pushing.
- `--no-stage` must use existing staged changes and must not stage automatically.
- Do not add telemetry, analytics, or new network calls without explicit discussion.
- Do not place secrets, tokens, sensitive internal hosts, or private logs in test fixtures, documentation, or debug output.

## Verification

Run the basic validation after changing `git-ai.sh` or related behavior:

```bash
bash -n git-ai.sh
shellcheck git-ai.sh
./git-ai.sh --help >/tmp/git-ai-help.txt
```

For runtime changes, test in a temporary repository and use dry-run:

```bash
tmpdir=$(mktemp -d)
git init "$tmpdir"
cd "$tmpdir"
git config user.name "git-ai test"
git config user.email "git-ai-test@example.invalid"
printf 'hello\n' > sample.txt
/path/to/git-auto-commit-ollama/git-ai.sh --dry-run --no-push --no-banner --no-pull
```

This smoke test still requires an active Ollama endpoint and an available model. If Ollama is unavailable, do not fabricate a runtime result. Report that runtime validation was not run and explain why.

## Review Output

When finishing a task, summarize:

- Files changed.
- Validation performed.
- Validation not performed and why.
- Remaining risks or relevant follow-up work.
