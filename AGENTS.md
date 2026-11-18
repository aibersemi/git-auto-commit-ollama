# AGENTS.md

These instructions apply to the entire `git-auto-commit-ollama` repository.

## Purpose

This project is a Bash CLI that generates Git commit messages with Ollama. Treat changes to staging, commits, pushes, secret scanning, prompt generation, and Ollama endpoints as high-risk areas.

## Language

- Use Bahasa Indonesia for conversations with the user, explanations, and work summaries.
- Use English for every repository artifact, including source code, code comments, help text, prompts, user-facing output, errors, debug messages, generated commit messages, configuration comments, documentation, templates, workflows, and agent instructions.
- Keep technical terms, headings, API and library names, commands, file and branch names, and other established identifiers in their conventional English form.

## Documentation

- In `AGENTS.md`, `README.md`, and all Markdown files under `docs/`, write each paragraph and list item text on a single line without hard wrapping. Avoid trailing whitespace and consecutive blank lines; preserve line breaks and indentation required by Markdown structures and code blocks.
- Update the root `README.md` whenever the project overview, features, how it works, structure, modules, or documentation navigation changes.
- Update the root `AGENTS.md` whenever core AI agent instructions, workflow rules, or repository policies change.
- Update `.github/CONTRIBUTING.md` whenever the contribution workflow, pull request validation, or coding standards change.
- Update `.github/SECURITY.md` whenever vulnerability scope, reporting procedures, disclosure policies, user safety, or security design notes change.
- Create or update relevant documents under `docs/` to directly reflect the current state of the system without recording changelogs, change history, or past migrations. If a system component is removed, also remove its descriptions and references from the documentation; do not replace them with notes such as "removed", "no longer used", or "previously used". If a component is replaced, document the replacement as the current state without discussing the previous implementation.
- Update documentation only when behavior, commands, architecture, operations, or data contracts change; cosmetic changes do not require documentation updates.
- Place information in the document with the most relevant scope, avoid duplicating details across documents, and use relative links for cross-references between topics.

## Work Rules

- Read the relevant files before changing them.
- Do not run destructive Git commands such as `git reset --hard` or a forced checkout unless the user explicitly requests it.
- Do not run `make install`, `make uninstall`, or commands that modify the global system unless the user explicitly requests it.
- Do not run `git-ai` to create a real commit unless the user explicitly requests it. Use `--dry-run` for runtime testing.
- Do not change the default model, default push behavior, fallback host, or commit message format without a clear reason and corresponding documentation updates.
- Do not add a required dependency without updating `check_deps`, the README, the contribution guide, and the [installation prerequisites](docs/installation.md#prerequisites).

## Bash Style

- Preserve `#!/usr/bin/env bash` and `set -euo pipefail`.
- Follow the existing function and output style in `git-ai.sh`.
- Use English for all comments, help text, prompts, user-facing output, errors, and debug messages in `git-ai.sh`.
- Quote variable expansions unless there is a clear Bash-specific reason not to.
- Use `jq` for JSON instead of ad hoc string parsing.
- Validate configuration values and CLI arguments as close as practical to the existing parsing and checking logic.
- When adding a CLI option, update `parse_args`, `show_help`, the README, the [CLI reference](docs/usage.md#options), and relevant help validation.
- When changing configuration, update `git-ai.conf`, fallback defaults, configuration validation, the README, and the [configuration reference](docs/configuration.md).

## Security

- Safe mode and the secret guard must remain conservative by default.
- `--force-diff` and `--allow-secret-commit` must remain explicit overrides.
- `--dry-run` must not create a commit, push, or permanently change Git state. It may still contact Ollama and, without `--no-pull`, pull a missing model.
- `--no-push` must always prevent pushing.
- `--no-stage` must use existing staged changes and must not stage automatically.
- Do not add telemetry, analytics, or new network calls without explicit discussion.
- Do not place secrets, tokens, sensitive internal hosts, or private logs in test fixtures, documentation, or debug output.

## Verification

For documentation changes, follow [Documentation Verification](docs/verification.md#documentation-verification).

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
