# Installation

[Documentation index](../README.md#documentation)

## Prerequisites

The CLI targets Linux with Bash and GNU userland. The generation workflow checks for `git`, `curl`, `jq`, `flock` from `util-linux`, and `gitleaks`. It also uses standard tools such as `awk`, `grep` with PCRE support, `sed`, `sort`, `mktemp`, `date`, and `wc`.

On Ubuntu or Debian, install the base tools with these commands.

```bash
sudo apt-get update
sudo apt-get install -y bash git curl jq util-linux coreutils grep sed
```

Install Gitleaks using its [installation instructions](https://github.com/gitleaks/gitleaks#installing) or [release binaries](https://github.com/gitleaks/gitleaks/releases). The CLI needs support for `git --pre-commit --staged`, JSON reports, redaction, and a custom findings exit code. See [CI](automation.md#continuous-integration) for the validated version. The executable must be on `PATH` even when `--force` skips the scan.

Install `make` and `sudo` to use the system symlink targets. The `ollama` CLI is required locally only for automatic model pulls. `tput` is optional for reading terminal dimensions. Verification tools are listed in [Verification](verification.md).

## Prepare Ollama

The Ollama endpoint must be reachable from the machine running `git-ai`. For a local installation, start Ollama with `ollama serve` if it is not already running, then run `ollama pull gemma4:e4b` in another terminal to install the shipped default model. For a network endpoint, make the model available on that server and review both hosts in [Configuration](configuration.md#ollama-host-resolution).

## Run from a Checkout

```bash
git clone https://github.com/aibersemi/git-auto-commit-ollama.git
cd git-auto-commit-ollama
./git-ai.sh --version
./git-ai.sh --help
```

For normal usage, change to the repository you want to operate on and invoke the script by its absolute path. Git operations target the working directory, while configuration is resolved from the executable path.

## Install the `git-ai` Command

Run `make install` from the checkout. It uses `sudo` to create `git-ai` and `git-ai.conf` symlinks in `$(PREFIX)/bin`, defaults to `/usr/local/bin`, and makes `git-ai.sh` executable. Both symlinks point into the checkout, so keep that directory in place and make sure the destination is on `PATH`.

```bash
make install
# Or install under a custom prefix.
make install PREFIX=/opt/git-ai
```

## Uninstall

Run `make uninstall` for the default prefix or `make uninstall PREFIX=/opt/git-ai` for the example custom prefix. The target removes the two installed symlinks and leaves the checkout in place.
