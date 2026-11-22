# Repository Automation

[Documentation index](../README.md#documentation)

The repository uses GitHub Actions for validation, release publication, and stale issue maintenance. Local CLI installation is covered in [Installation](installation.md).

## Continuous Integration

[CI](../.github/workflows/ci.yml) checks workflow syntax, Bash syntax, ShellCheck, and CLI help on pushes to `main` and pull requests. The Bash validation job uses `ubuntu-24.04`, read-only repository contents access, and a 15-minute timeout.

Full validation also lints the test scripts and runs the three [regression suites](verification.md#local-checks). For a manual run, select **Run all regression suites** in the **Run workflow** menu to enable full validation. Reusable workflow calls run full validation by default and can set `full_validation: false` to run the basic checks.

Checkout uses `actions/checkout` v7.0.1 with a full commit SHA and `persist-credentials: false`. The job uses ShellCheck and jq from the runner image and installs actionlint `1.7.12` from a release archive verified against a pinned SHA-256 sum. Full validation installs Gitleaks `8.30.1` with the same checksum verification. Keep action references pinned, and validate runner changes separately before changing the shared baseline.

CI groups runs by workflow and pull request number or ref. A new run cancels an older run in the same group for non-tag refs. Tag validation runs are not canceled by this rule.

## Releases

[Release](../.github/workflows/release.yml) triggers on pushes of `v*` tags. The tag validation job accepts `vMAJOR.MINOR.PATCH` with no leading zeros or suffixes. The tagged commit must pass full validation through the reusable CI workflow before release publication. The publication job creates a GitHub Release with generated notes from an existing remote tag by running `gh release create --verify-tag`.

Release runs are grouped by tag ref with cancellation disabled. Tag validation and publication run on `ubuntu-24.04` with a five-minute timeout each. Repository access is read-only during validation. Only the publication job receives `contents: write` and uses the workflow token through `GH_TOKEN`.

## Stale Maintenance

[Stale](../.github/workflows/stale.yml) runs daily at 01:30 UTC with a ten-minute timeout and serialized runs. The job uses `ubuntu-24.04`, pins `actions/stale` v11.0.0 to a full commit SHA, and grants only `issues: write` and `pull-requests: write` for its work.

Issues and pull requests become stale after 60 days of inactivity. Stale issues may close after another seven days, while pull requests stay open for review. The labels `bug`, `enhancement`, and `security` exempt both types when assigned. Draft pull requests are also exempt.
