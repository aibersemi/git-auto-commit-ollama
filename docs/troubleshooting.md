# Troubleshooting

[Documentation index](../README.md#documentation)

Use the message from the CLI or underlying command to identify the failing stage. `git-ai --status` can check Git status without Ollama preflight. Use `git-ai --help` to locate the selected configuration file.

| Symptom | What to check |
| --- | --- |
| `Ollama is unavailable ...` | Check service availability, reachability, and both configured hosts. Fallback is only attempted after a failed tags request. See [Ollama Host Resolution](configuration.md#ollama-host-resolution). |
| `Selected model ... was not found` | Check the model name and active server. Pull the model on that server, install the local `ollama` executable for automatic pulling, or select an available model with `--model`. |
| `Failed to load and verify model ...` or readiness ping failed | Check Ollama logs, connectivity, and available resources. The model can appear in `/api/tags` while `/api/chat` still fails. See the [request contract](commit-generation.md#ollama-request-contract). |
| `--no-stage` reports no staged changes | Stage the intended files, or choose the appropriate [staging mode](usage.md#staging-and-commit-review). |
| `git-ai is already running ...` | Check for an active run in the same Git directory and wait for it to finish. See [Runtime Flow](architecture.md#runtime-flow). |
| Commit canceled because of a potential secret | Remove the credential from staged changes and rescan. See [Overrides](../.github/SECURITY.md#overrides) for the distinction between a finding and diff transmission. |
| Gitleaks missing or scan failed | Install a compatible executable and check the chosen configuration, includes, and scanner version. See [Scanner Configuration](../.github/SECURITY.md#scanner-configuration). |
| `Retry` or `AI response rejected` | Read the preceding availability message or validation reason. Check the model and prompt budget if the issue repeats. See [Fallbacks and Retries](commit-generation.md#fallbacks-and-retries). |
| Commit hook fails | Fix the failing `pre-commit` or `commit-msg` check. See [Push Behavior and Hooks](usage.md#push-behavior-and-hooks) for the scope of `--no-verify`. |
| Push or `pre-push` hook fails | Check the Git error, remote configuration, authentication, and hook output. The local commit already exists. Verify its state before retrying the push. |
| Push skipped because there is no remote | Configure a remote if you intend to push. See [Push Behavior and Hooks](usage.md#push-behavior-and-hooks) for destination selection. |
| The installed command disappeared after moving the checkout | Inspect the symlink using `readlink -f "$(command -v git-ai)"`. Restore the checkout path or [reinstall](installation.md#install-the-git-ai-command) from its new location. |
| Configuration edits appear ignored | Check the configuration path reported by `git-ai --help`, especially when multiple checkouts or installations exist. See [Config File Resolution](configuration.md#config-file-resolution). |

When ordinary output is insufficient, use `--debug` in a trusted terminal and follow the [debug handling guidance](../.github/SECURITY.md#debug-output). For reporting a problem, follow the [Support Guide](../.github/SUPPORT.md).
