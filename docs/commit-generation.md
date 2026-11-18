# Commit Message Generation

[Documentation index](../README.md#documentation)

## Prompt Routing

Generation reads staged changes from the selected index, including the temporary index in dry-run. The CLI collects Git status entries, statistics, summaries, and change classifications. Detailed references exclude generated or ephemeral paths, binary diffs, oversized staged blobs, and sensitive file diffs subject to the [security policy](../.github/SECURITY.md#security-controls). Excluded files can still affect metadata and classification. The prompt lists selected reference paths separately from the Git entries capped by `MAX_FILES_LIST`.

| Condition | Context sent to final generation |
| --- | --- |
| Safe mode is off and the complete eligible diff fits | Full eligible diffs with file headers, hunk order, additions, deletions, and unchanged diff context. The fast path skips per-file analysis and ignores fallback excerpt and file-selection limits. |
| Safe mode is off and the complete diff does not fit | Ranked excerpts and optional per-file summaries. If analysis is unavailable, usable excerpts remain. |
| Safe mode is active | Git metadata and any eligible per-file summaries. Detailed diffs and diff-derived terms are omitted from the final prompt. |
| No eligible detail is available | Git metadata. Missing eligible runtime evidence is reported as limited context. |

The full-diff check includes system instructions, metadata, and user prompt plus the correction reserve defined in [Configuration](configuration.md#context-and-analysis-limits). Each chat request also checks the actual prompt length before transmission, including correction text. If the prompt exceeds the limit, the request fails locally.

## Reference Ranking and Change Classification

Classification checks documentation, CI, and tests before runtime keywords such as `security`, `api`, or `schema`. Runtime source may include templates, stylesheets, executable code, and runtime configuration. A JavaScript or TypeScript change can count as documentation when only Markdown paths or anchors change inside the first plain module JSDoc block and the rest of the file is identical. This narrow check can recognize a block after simple directives or single-line imports and requires an existing regular file with unchanged mode.

The informative Markdown ranking applies to staged `.md` files regardless of extension case. It scores the eligible diff before trimming excerpts. It ignores diff headers, headings, fence delimiters, and URL-only or link-only lines. After normalizing case and punctuation, Markdown qualifies with at least 12 added words and 8 net-new word occurrences. The score sums positive increases in per-word occurrence counts. Runtime files are ranked by added plus removed lines. Path order breaks ties.

When both runtime and informative Markdown are available, the first two reference slots contain the highest-ranked runtime file and the highest-ranked Markdown file. Remaining runtime files come next, followed by remaining informative Markdown and then supporting files. With `TOP_FILES=1`, runtime gets the first excerpt. Per-file analysis follows the same order within its file limit. Short documentation edits, deletions, and renames can provide context when informative Markdown is unavailable.

Fallback excerpts rank complete hunks by informative text changes for qualified Markdown and changed-line count otherwise. They compact up to four hunks per file, place additions before removals, and retain up to three unchanged source lines such as conditions, returns, or declarations per compacted hunk. Unchanged context keeps the diff space prefix. Long prose changes trim repeated prefixes and suffixes, and long source hunks sample changed lines across the beginning, middle, and end. File labels and excerpts share the total budget, with space reserved across the selected files. Limits preserve Unicode character boundaries.

The prompt asks the model to describe completed changes, lead with implemented behavior when runtime work is present, and use informative Markdown, tests, and CI as supporting evidence. When classification identifies documentation work, it requests a concrete guidance topic and type `docs`. Without runtime work, CI takes precedence over tests, and test work uses type `test` when CI is absent. Classification and quality checks are heuristic. Review the message against the actual changes.

## Per-File Analysis

Fallback analysis selects eligible files up to `FILE_ANALYSIS_LIMIT`. Each worker processes one file from the same index and sends its complete eligible diff in one or more bounded requests. Chunks preserve diff order and repeat file and hunk headers as needed. Splits occur at hunk boundaries, then at line boundaries within oversized hunks, then at Unicode character boundaries within exceptionally long lines. Multi-chunk analysis consolidates the chunk summaries into one result per file before final generation.

Per-file analysis requests JSON Schema output with the exact file name and a one-sentence English analysis of at most 30 words. Results with no usable summary for the expected file fall back locally. If safe mode permits detailed excerpts, the local excerpt remains available. `--no-file-analysis` and `FILE_ANALYSIS_LIMIT=0` skip these requests while preserving full-diff generation and eligible local excerpts. See [Worker Capacity](configuration.md#worker-capacity) for scheduling and [Terminal Output](usage.md#terminal-output) for progress behavior.

## Ollama Request Contract

| Request | Purpose | Total timeout |
| --- | --- | --- |
| `GET /api/tags` | Select a reachable endpoint and match the requested model against listed names. | 10 seconds |
| `GET /api/ps` | Check whether the selected model is loaded. A failed check proceeds to warm-up. | 10 seconds |
| `POST /api/chat` with empty `messages` | Check readiness of a loaded model or warm up an unloaded model. Requires `done: true` and a string `model`. | 300 seconds |
| `POST /api/chat` for per-file analysis | Analyze one file or chunk or consolidate chunk summaries. | 60 seconds |
| `POST /api/chat` for final generation | Generate or correct the commit message. | 120 seconds |

Each request uses a five-second connection timeout. Analysis and generation send non-streaming chat requests with the model, system and user messages, sampling options, and thinking control. Structured requests also send a JSON Schema in `format`. The CLI expects a successful HTTP response with JSON containing nonempty `message.content`. It reports token counts from `prompt_eval_count` and `eval_count` when provided.

## Commit Message Format

The emitted subject uses `<type>: <summary>` without a scope. The summary must have at least eight characters and end without a period. A single staged file produces a subject only. Multiple staged files require a blank line and one to six distinct `- ` bullets, each ending in a period. The prompt requests imperative English and groups related changes by the behavior they implement. `MAX_COMMIT_MESSAGE_LENGTH` caps the entire normalized message. There is no separate subject-length maximum.

| Type | Primary change |
| --- | --- |
| `build` | Build system, packaging, or build tooling. |
| `chore` | Routine maintenance without a more specific type. |
| `ci` | CI or release automation. |
| `deps` | Dependencies or lockfiles. |
| `docs` | Documentation and guidance. |
| `feat` | New domain, user-facing, or API capability. |
| `fix` | Bug fix or correction of unintended behavior. |
| `perf` | Performance improvement. |
| `refactor` | Code restructuring without a feature or fix. |
| `revert` | Reversal of earlier work. |
| `style` | Non-behavioral formatting changes. |
| `test` | Test coverage or fixture maintenance. |

Use the type that describes the primary change. For example, tests and dependency updates supporting a feature belong under the feature's `feat` message. The quality checks can reject supporting themes in the subject or first bullet when runtime changes are present, generic subjects, or specific unsupported themes. Runtime behavior involving test inputs is classified from source changes rather than from the mention of tests alone.

The structured path requests `type`, `summary`, and `bullets` before composing plain commit text. Both structured and plain parsing normalize paired single-backtick inline code, ampersands, and punctuation. Scopes, unmatched backticks, code fences, control characters, unsupported formatting, and invalid or duplicate bodies can trigger rejection. Plain parsing can convert additional scope-free candidate subjects into bullets when multiple files are staged.

## Fallbacks and Retries

The CLI stops after 10 generation attempts or three invalid commit-message responses, whichever is reached first. An unavailable request uses attempt time without counting as an invalid message. When structured output is enabled, a valid plain commit message returned to a structured request can be accepted. A structured request failure falls back to plain text within the same attempt. A response that fails structured composition or plain parsing counts toward the invalid-response limit before fallback. A format-valid response rejected by quality checks receives a corrective retry in the active response format.

Retry waits start at one second and increase by one second per attempt, capped at 10 seconds. Rejection reasons appear without `--debug` and may identify the subject, first bullet, or invalid field. Corrective prompts include the rejected content and reason. Exhaustion exits before committing or pushing and preserves staged changes in a regular run.
