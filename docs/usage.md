# CLI Usage

[Documentation index](../README.md#documentation)

Run `git-ai` in the Git working tree whose changes you want to commit. Use the absolute path to `git-ai.sh` if you run it directly from a checkout. See [Installation](installation.md) for setup.

## Staging and Commit Review

The default staging mode runs `git add -A`, including additions, modifications, and deletions across the repository, subject to Git's ignore and staging rules. Use `--patch` to select hunks with `git add -p`, or `--no-stage` to reuse the existing index. `--no-stage` takes precedence over `--patch`. When there are working-tree changes but no staged changes, `--no-stage` reports an error. A clean repository or an empty index after interactive staging ends the run without a commit. Full runs check [Ollama readiness](configuration.md#ollama-host-resolution) before checking for changes.

```bash
git-ai --no-stage --interactive --no-push
git-ai --patch --interactive --no-push
git-ai --status
```

With `--interactive`, accept the generated message, decline with `n`, or edit it with `e`. An empty edit cancels the commit. The editor comes from `EDITOR` and defaults to `vi`. Generated messages pass [format and quality checks](commit-generation.md#commit-message-format) before review. Edited text goes to Git without another CLI validation pass. Staging takes place before message review and remains in the real index if generation fails or the user cancels.

## Dry Run

Use `git-ai --dry-run --no-pull` to preview a message. The CLI copies the current index to a temporary directory or starts with an empty index. Git writes new blobs and other objects to a temporary object database and reads existing objects through Git alternates. Staging, secret scanning, and reference collection share the temporary index and can read both sets of objects.

Dry-run preserves the original index contents, refs, working files, and stored Git objects. Git can refresh timestamps on existing objects or shared index files it reuses. Dry-run skips interactive commit review, commit hooks, commits, and pushes. The CLI removes its temporary directory on process exit, including after a scan or generation failure.

Ollama preflight, model warm-up, and generation still run. Without `--no-pull`, a missing model can be pulled when the local `ollama` executable is available. The [Gitleaks policy](security.md#overrides) describes how dry-run handles findings and scan failures.

## Push Behavior and Hooks

With push enabled, a branch with an upstream runs plain `git push`, which follows Git's configuration. Without an upstream, the CLI runs `git push -u` to `origin` or, if `origin` is absent, the first remote Git lists. It skips the push when no remote exists. A push failure leaves the local commit in place. `--no-push` suppresses pushing regardless of the configured default.

`--no-verify` is passed only to `git commit`. It bypasses `pre-commit` and `commit-msg`; `pre-push` still runs when Git pushes.

## Options

`git-ai --help` prints the command synopsis and selected configuration path. The following options are accepted by the CLI.

| Option | Effect |
| --- | --- |
| `-h`, `--help` | Show help and exit. |
| `-v`, `--version` | Show the CLI version and exit. |
| `-s`, `--status` | Run `git status` and exit before Ollama and scanner checks. |
| `-n`, `--no-push` | Skip pushing after a commit. |
| `-m MODEL`, `--model MODEL`, `--model=MODEL` | Override the model for this invocation, including availability checks, pull, warm-up, analysis, and generation. |
| `-p`, `--patch` | Stage interactively with `git add -p`. |
| `-i`, `--interactive` | Review or edit the generated message before committing. |
| `--no-stage` | Use existing staged changes. |
| `-d`, `--dry-run` | Generate a preview using a temporary index and object database. |
| `--debug` | Print diagnostics. See [Debug Output](security.md#debug-output) for exposure limits. |
| `--force-diff` | Override safe mode for diff transmission. See [Overrides](security.md#overrides). |
| `-f`, `--force` | Skip the scan and override safe mode. See [Overrides](security.md#overrides). |
| `-a`, `--allow-secret-commit` | Allow a commit despite a successful scan with findings. See [Overrides](security.md#overrides). |
| `--no-file-analysis` | Disable fallback per-file requests. |
| `--file-analysis-limit N` | Override the file analysis limit with a non-negative integer. |
| `--file-analysis-batch-size N` | Accept a positive integer for compatibility. Each request still covers one file. |
| `--file-analysis-parallelism N\|auto` | Set a positive worker limit or use [capacity detection](configuration.md#worker-capacity). |
| `--non-ai-parallelism N\|auto` | Set a positive local worker limit or derive it from the logical CPU count. |
| `--no-structured` | Use plain text for final commit-message generation. Per-file analysis still uses JSON Schema. |
| `--no-pull` | Stop if the selected model is missing instead of running `ollama pull`. |
| `--no-banner` | Hide the startup banner. |
| `--no-verify` | Pass `--no-verify` to `git commit`. |

## Terminal Output

The CLI prints English phase statuses, the generated message, and reported token usage. Git, Ollama, and other tools may use their own language. The run displays a commit hash after a successful non-preview run.

When standard error is a terminal, the CLI animates loading rows and shows an estimated AI progress bar. From 0% through 95%, the estimate advances by one point per interval. Each interval is 10 milliseconds multiplied by the total number of staged files, with a minimum of 10 milliseconds. After 95%, it advances by one point every two seconds and holds at 99%. A validated message advances the bar directly to 100% at any time. The same clock covers file analysis, generation, and retries.

The file counter advances once per completed file, including local fallbacks, and progress rows show active files. Non-terminal output prints phase statuses and numbered completions without animated frames. Set `NO_COLOR` to disable colors while preserving terminal animation.
