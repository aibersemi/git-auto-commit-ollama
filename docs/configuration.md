# Configuration

[Documentation index](../README.md#documentation)

## Config File Resolution

The CLI looks for `git-ai.conf` next to the executable path used to invoke it. If that file is absent and `readlink -f` resolves the executable, the CLI looks next to the resolved script. Use `git-ai --help` to see the selected path. The file is sourced as Bash before argument parsing, so use trusted code and keep credentials out of it.

File assignments override inherited values for the same variables. Bash fallbacks apply to unset or empty values where the script defines a fallback. Options such as `--model` and `--no-push` override the effective settings for one invocation. The tables show values shipped in [`git-ai.conf`](../git-ai.conf). In the absence of a config file or inherited values, the script enables structured final output and leaves both host settings empty before host resolution. It uses the same fallback values for the other listed settings.

## Ollama and Commit Settings

| Setting | Shipped value | Contract |
| --- | --- | --- |
| `DEFAULT_MODEL` | `gemma4:e4b` | Model used unless `--model` is supplied. |
| `DEFAULT_OLLAMA_HOST` | `http://127.0.0.1:11434` | Primary endpoint. Empty value uses service discovery. |
| `FALLBACK_OLLAMA_HOST` | See `git-ai.conf` | Secondary endpoint. Set to an empty string to disable fallback. |
| `DEFAULT_DO_PUSH` | `1` | Push after committing. Set `0` to disable it. The script also recognizes `true`/`false`, `yes`/`no`, and `on`/`off` in all-lowercase or all-uppercase forms. |
| `AI_TEMPERATURE` | `0.2` | Non-negative numeric request temperature. |
| `AI_THINK` | `false` | Accepts `false`, `true`, `low`, `medium`, or `high`. The first two are sent as JSON booleans. |
| `AI_NUM_PREDICT` | `512` | Non-negative output-token setting for final message generation, capped by `AI_MAX_NUM_PREDICT`. |
| `AI_MAX_NUM_PREDICT` | `2048` | Positive upper bound for output tokens in final generation and file analysis. |
| `USE_STRUCTURED_OUTPUT` | `0` | `1` requests JSON Schema for final generation. `0` uses plain text and is shipped for the default model. |
| `MAX_COMMIT_MESSAGE_LENGTH` | `65536` | Maximum total message length in characters. Must be at least `24`. |

Unset or empty `AI_TEMPERATURE`, `AI_THINK`, `AI_NUM_PREDICT`, and `AI_MAX_NUM_PREDICT` can fall back to `OLLAMA_TEMPERATURE`, `OLLAMA_THINK`, `OLLAMA_NUM_PREDICT`, and `OLLAMA_MAX_NUM_PREDICT`, respectively, before the built-in values apply.

## Ollama Host Resolution

1. Use `DEFAULT_OLLAMA_HOST` if set to a nonempty value.
2. Otherwise, read `OLLAMA_HOST` from `systemctl show ollama.service --property=Environment --value`, then from `/etc/systemd/system/ollama.service` if the service environment provides no match.
3. Use `http://localhost:11434` if no service value is available.

The CLI does not consult the caller's `OLLAMA_HOST` for primary endpoint selection. Host normalization defaults to HTTP, preserves explicit HTTPS, strips a trailing slash, and maps wildcard listeners `0.0.0.0` and `[::]` to `127.0.0.1`.

A nonempty, distinct `FALLBACK_OLLAMA_HOST` is tried only when the primary `/api/tags` request fails. The endpoint selected by that check stays active for the rest of the run. A successful tags request with a missing model, a readiness error, or a generation error does not switch hosts. An automatic pull invokes `ollama pull` with `OLLAMA_HOST` set to the active endpoint. See [Data Sent to Ollama](../.github/SECURITY.md#data-sent-to-ollama).

## Context and Analysis Limits

| Setting | Shipped value | Contract |
| --- | --- | --- |
| `MAX_PROMPT_CHARS` | `48000` | Combined system and user prompt budget, from `16384` to `65536` characters. Initial full-diff selection reserves `4096` characters for corrections. |
| `MAX_FILES_LIST` | `20` | Display limit for Git file status, statistics, summary, and priority-change entries in the prompt. |
| `TOP_FILES` | `4` | Maximum ranked references used for fallback excerpts. |
| `MAX_HUNK_CHARS` | `1000` | Maximum characters per fallback excerpt. |
| `MAX_TOTAL_HUNKS_CHARS` | `3500` | Total character budget for fallback excerpts, including file labels. |
| `FILE_ANALYSIS_LIMIT` | `6` | Non-negative maximum files analyzed during fallback. `0` disables per-file requests. |
| `FILE_ANALYSIS_BATCH_SIZE` | `1` | Positive compatibility setting. The CLI handles one file per worker regardless of this value. |
| `FILE_ANALYSIS_NUM_PREDICT_PER_FILE` | `192` | Positive output-token limit for each file analysis request, capped by `AI_MAX_NUM_PREDICT`. |
| `FILE_ANALYSIS_MAX_BLOB_BYTES` | `1048576` | Positive staged blob size limit for detailed context and per-file requests. |

The prompt budget counts characters. It does not measure model tokens or change the model context window. See [Prompt Routing](commit-generation.md#prompt-routing) for how these limits interact.

## Worker Capacity

| Setting | Shipped value | Contract |
| --- | --- | --- |
| `NON_AI_PARALLELISM` | `auto` | Positive local worker limit, or `auto` to use the logical CPU count from `nproc` or `getconf` with a fallback of `1`. |
| `FILE_ANALYSIS_PARALLELISM` | `auto` | Positive limit for concurrent per-file AI workers, or `auto` for endpoint-aware detection. |
| `OLLAMA_PARALLELISM_HINT` | Empty | Optional positive capacity hint, useful for remote or containerized endpoints. |

AI capacity resolves after endpoint selection. In order, it uses a numeric `FILE_ANALYSIS_PARALLELISM`, `OLLAMA_PARALLELISM_HINT`, `OLLAMA_NUM_PARALLEL` from the local service lookup, `OLLAMA_NUM_PARALLEL` from the process environment for a local endpoint, then `1`. The CLI recognizes `localhost`, IPv4 loopback, and `[::1]` as local. A remote endpoint without an explicit setting or hint therefore uses one worker.

Both limits cap ready work. A capacity of four allows at most four simultaneous file analyses, with remaining files filling slots as workers finish. Capacity one runs AI requests in the foreground while the terminal renderer may run in the background. Final results preserve reference order even when workers complete out of order. See [Per-File Analysis](commit-generation.md#per-file-analysis).
