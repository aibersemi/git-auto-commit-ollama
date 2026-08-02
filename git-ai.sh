#!/usr/bin/env bash
#
# git-ai.sh - Git AI Commit Assistant (Ollama)
# ------------------------------------------------------
# Summary:
# - Auto-stage (optional) -> generate a commit message with Ollama -> commit -> push (optional)
# - Message format: Conventional Commit subject with an optional bullet body
# - Safe mode: hide detailed diffs when sensitive patterns are detected
# - Optional per-file analysis (limited) for a more concise prompt
# - Structured output (Ollama `format`/JSON Schema) for more consistent results
#
# Dependencies: git, curl, jq, flock
#
# Quick usage:
#   /opt/services/utils/bin/git-ai.sh                 # stage all, generate commit message, push
#   /opt/services/utils/bin/git-ai.sh -n              # commit without pushing
#   /opt/services/utils/bin/git-ai.sh -p              # git add -p
#   /opt/services/utils/bin/git-ai.sh --dry-run       # only display the commit message
#
# Config:
#   git-ai.conf                     # configuration next to the executable or symlink target
#

set -euo pipefail

# ===== Version =====
VERSION="1.5.1"

# ===== Configuration =====
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_CONFIG_FILE="${SCRIPT_DIR}/git-ai.conf"

# Keep an adjacent config as the first choice. If the executable is a symlink
# without its own config, use the config next to the resolved script target.
if [[ ! -f "$SCRIPT_CONFIG_FILE" ]] && command -v readlink >/dev/null 2>&1; then
  RESOLVED_SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  if [[ -n "$RESOLVED_SCRIPT_PATH" ]]; then
    RESOLVED_SCRIPT_DIR="$(cd -- "$(dirname -- "$RESOLVED_SCRIPT_PATH")" && pwd -P)"
    RESOLVED_CONFIG_FILE="${RESOLVED_SCRIPT_DIR}/git-ai.conf"
    if [[ -f "$RESOLVED_CONFIG_FILE" ]]; then
      SCRIPT_CONFIG_FILE="$RESOLVED_CONFIG_FILE"
    fi
  fi
fi

# Load the selected config file when present.
# shellcheck source=/dev/null
[[ -f "$SCRIPT_CONFIG_FILE" ]] && source "$SCRIPT_CONFIG_FILE"

# ===== Behavior =====
DO_PUSH="${DEFAULT_DO_PUSH:-1}"
DO_STAGE=1
USE_PATCH=0
DRY_RUN=0
DEBUG=0
FORCE_DIFF=0
ALLOW_SECRET_COMMIT=0
NO_BANNER=0
NO_PULL=0
NO_VERIFY=0
INTERACTIVE=0
DRY_RUN_INDEX_FILE=""
STAGED_FILE_COUNT=0
MODEL_OVERRIDE=""

# Per-file analysis tuning
DO_FILE_ANALYSIS=1

# Structured output (Ollama `format`)
USE_STRUCTURED_OUTPUT="${USE_STRUCTURED_OUTPUT:-1}"

# Minimal fallback when the config file is unavailable or its value is empty.
DEFAULT_MODEL="${DEFAULT_MODEL:-gemma4:e4b}"
DEFAULT_OLLAMA_HOST="${DEFAULT_OLLAMA_HOST:-}"
FALLBACK_OLLAMA_HOST="${FALLBACK_OLLAMA_HOST:-}"
AI_TEMPERATURE="${AI_TEMPERATURE:-${OLLAMA_TEMPERATURE:-0.2}}"
AI_THINK="${AI_THINK:-${OLLAMA_THINK:-false}}"
AI_NUM_PREDICT="${AI_NUM_PREDICT:-${OLLAMA_NUM_PREDICT:-2048}}"
AI_MAX_NUM_PREDICT="${AI_MAX_NUM_PREDICT:-${OLLAMA_MAX_NUM_PREDICT:-2048}}"
FILE_ANALYSIS_LIMIT="${FILE_ANALYSIS_LIMIT:-6}"
FILE_ANALYSIS_NUM_PREDICT_PER_FILE="${FILE_ANALYSIS_NUM_PREDICT_PER_FILE:-512}"
FILE_ANALYSIS_PARALLELISM="${FILE_ANALYSIS_PARALLELISM:-4}"
MAX_FILES_LIST="${MAX_FILES_LIST:-20}"
TOP_FILES="${TOP_FILES:-4}"
MAX_HUNK_CHARS="${MAX_HUNK_CHARS:-1000}"
MAX_TOTAL_HUNKS_CHARS="${MAX_TOTAL_HUNKS_CHARS:-3500}"
MAX_COMMIT_MESSAGE_LENGTH="${MAX_COMMIT_MESSAGE_LENGTH:-65536}"
MAX_BODY_BULLETS=6

case "$DO_PUSH" in
  true|TRUE|yes|YES|on|ON) DO_PUSH=1 ;;
  false|FALSE|no|NO|off|OFF|"") DO_PUSH=0 ;;
esac

# The effective model may be overridden for a single invocation with -m/--model.
OLLAMA_MODEL="$DEFAULT_MODEL"
OLLAMA_SERVICE_FILE="/etc/systemd/system/ollama.service"

read_ollama_service_env() {
  local key="$1"
  local line value

  [[ -r "$OLLAMA_SERVICE_FILE" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*Environment= ]] || continue
    line="${line#*=}"
    line="${line%$'\r'}"
    line="${line#\"}"
    line="${line%\"}"
    [[ "$line" == "$key="* ]] || continue
    value="${line#"$key="}"
    printf '%s' "$value"
    return 0
  done < "$OLLAMA_SERVICE_FILE"

  return 1
}

normalize_ollama_host_url() {
  local raw="${1:-}"
  local scheme="http"

  if [[ -z "$raw" ]]; then
    printf '%s' "http://localhost:11434"
    return 0
  fi

  raw="${raw#\"}"
  raw="${raw%\"}"
  raw="${raw%/}"

  if [[ "$raw" == http://* ]]; then
    raw="${raw#http://}"
  elif [[ "$raw" == https://* ]]; then
    scheme="https"
    raw="${raw#https://}"
  fi

  case "$raw" in
    0.0.0.0:*) raw="127.0.0.1:${raw#0.0.0.0:}" ;;
    0.0.0.0) raw="127.0.0.1" ;;
    "[::]:"*) raw="127.0.0.1:${raw#"[::]:"}" ;;
    "[::]") raw="127.0.0.1" ;;
  esac

  printf '%s://%s' "$scheme" "$raw"
}

resolve_ollama_base_url() {
  local configured_host service_host

  configured_host="${DEFAULT_OLLAMA_HOST:-}"
  if [[ -n "$configured_host" ]]; then
    normalize_ollama_host_url "$configured_host"
    return 0
  fi

  if service_host=$(read_ollama_service_env "OLLAMA_HOST"); then
    normalize_ollama_host_url "$service_host"
    return 0
  fi

  normalize_ollama_host_url ""
}

OLLAMA_BASE_URL="$(resolve_ollama_base_url)"

# Derived URL (must come after the config)
OLLAMA_API_URL="${OLLAMA_BASE_URL}/api/chat"
OLLAMA_PS_URL="${OLLAMA_BASE_URL}/api/ps"

# ===== Terminal output =====
# Interactive status indicators require a terminal; NO_COLOR only disables colors.
IS_TTY=0
[[ -t 2 ]] && IS_TTY=1

if [[ "$IS_TTY" -eq 1 && -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  MAGENTA='\033[0;35m'
  BOLD='\033[1m'
  DIM='\033[2m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' BOLD='' DIM='' NC=''
fi

info()    { echo -e "${BLUE}$*${NC}" 1>&2; }
warn()    { echo -e "${YELLOW}$*${NC}" 1>&2; }
err()     { echo -e "${RED}$*${NC}" 1>&2; }
die()     { err "Error: $*"; live_status_stop 2>/dev/null || true; spinner_stop 2>/dev/null; exit 1; }
dbg()     { if [[ "${DEBUG}" -eq 1 ]]; then echo -e "${CYAN}[debug]${NC} $*" 1>&2; fi; }

dbg_block() {
  [[ "${DEBUG}" -eq 1 ]] || return 0

  local label="$1"
  local content="${2:-}"
  printf '%b[debug]%b --- %s (begin) ---\n' "$CYAN" "$NC" "$label" >&2
  if [[ -n "$content" ]]; then
    printf '%s\n' "$content" >&2
  else
    printf '<empty>\n' >&2
  fi
  printf '%b[debug]%b --- %s (end) ---\n' "$CYAN" "$NC" "$label" >&2
}

dbg_command_output() {
  local command="$1"
  local output="${2:-}"

  dbg "Command: $command"
  dbg_block "Command output: $command" "$output"
}

validation_fail() {
  local code="$1"
  shift

  dbg "Validation failed [${code}]: $*"
  return 1
}

debug_runtime_configuration() {
  [[ "${DEBUG}" -eq 1 ]] || return 0

  local config
  config=$(cat <<EOF
script=${BASH_SOURCE[0]}
config=${SCRIPT_CONFIG_FILE}
model=${OLLAMA_MODEL}
model_source=$([[ -n "$MODEL_OVERRIDE" ]] && printf '%s' "command line" || printf '%s' "DEFAULT_MODEL")
default_model=${DEFAULT_MODEL}
model_override=${MODEL_OVERRIDE:-<empty>}
ollama_base_url=${OLLAMA_BASE_URL}
ollama_api_url=${OLLAMA_API_URL}
fallback_ollama_host=${FALLBACK_OLLAMA_HOST:-<empty>}
dry_run=${DRY_RUN}
stage=${DO_STAGE}
push=${DO_PUSH}
structured_output=${USE_STRUCTURED_OUTPUT}
file_analysis=${DO_FILE_ANALYSIS}
file_analysis_limit=${FILE_ANALYSIS_LIMIT}
file_analysis_parallelism=${FILE_ANALYSIS_PARALLELISM}
temperature=${AI_TEMPERATURE}
think=${AI_THINK}
num_predict=${AI_NUM_PREDICT:-<empty>}
max_num_predict=${AI_MAX_NUM_PREDICT}
EOF
)
  dbg_block "Runtime configuration" "$config"
}

refresh_ollama_urls() {
  OLLAMA_API_URL="${OLLAMA_BASE_URL}/api/chat"
  OLLAMA_PS_URL="${OLLAMA_BASE_URL}/api/ps"
}

resolve_ollama_fallback_url() {
  local fallback_host="${FALLBACK_OLLAMA_HOST:-}"

  [[ -n "$fallback_host" ]] || return 1
  normalize_ollama_host_url "$fallback_host"
}

fetch_ollama_tags() {
  local base_url="$1"
  local url="${base_url}/api/tags"
  local output tmp_err err_txt status
  tmp_err=$(mktemp)

  dbg "Command: curl -sSf --connect-timeout 5 --max-time 10 ${url}"
  if output=$(curl -sSf --connect-timeout 5 --max-time 10 "$url" 2>"$tmp_err"); then
    status=0
  else
    status=$?
  fi
  err_txt=$(cat "$tmp_err" || true)
  rm -f "$tmp_err"

  dbg "Command exit status: ${status}"
  dbg_block "Command output: curl GET ${url}" "$output"
  [[ -z "$err_txt" ]] || dbg_block "Command stderr: curl GET ${url}" "$err_txt"
  [[ "$status" -eq 0 ]] || return "$status"
  printf '%s' "$output"
}

fetch_ollama_running_models() {
  local output tmp_err err_txt status
  tmp_err=$(mktemp)

  dbg "Command: curl -sSf --connect-timeout 5 --max-time 10 ${OLLAMA_PS_URL}"
  if output=$(curl -sSf --connect-timeout 5 --max-time 10 "$OLLAMA_PS_URL" 2>"$tmp_err"); then
    status=0
  else
    status=$?
  fi
  err_txt=$(cat "$tmp_err" || true)
  rm -f "$tmp_err"

  dbg "Command exit status: ${status}"
  dbg_block "Command output: curl GET ${OLLAMA_PS_URL}" "$output"
  [[ -z "$err_txt" ]] || dbg_block "Command stderr: curl GET ${OLLAMA_PS_URL}" "$err_txt"
  [[ "$status" -eq 0 ]] || return "$status"
  printf '%s' "$output"
}

is_ollama_model_loaded() {
  local running_models="$1"

  jq -e --arg model "$OLLAMA_MODEL" \
    'any(.models[]?; .name == $model or .model == $model)' \
    >/dev/null <<<"$running_models"
}

ping_ollama_model() {
  local payload response tmp_err err_txt status
  tmp_err=$(mktemp)

  payload=$(jq -n --arg model "$OLLAMA_MODEL" '{model: $model, messages: [], stream: false}')
  dbg "Command: curl -sSf --connect-timeout 5 --max-time 300 -H 'Content-Type: application/json' -d '<payload>' ${OLLAMA_API_URL}"
  dbg_block "Ollama readiness payload" "$payload"
  if response=$(curl -sSf --connect-timeout 5 --max-time 300 \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$OLLAMA_API_URL" 2>"$tmp_err"); then
    status=0
  else
    status=$?
  fi
  err_txt=$(cat "$tmp_err" || true)
  rm -f "$tmp_err"

  dbg "Command exit status: ${status}"
  dbg_block "Ollama readiness response" "$response"
  [[ -z "$err_txt" ]] || dbg_block "Ollama readiness stderr" "$err_txt"
  [[ "$status" -eq 0 ]] || return "$status"

  if ! jq -e '(.done == true) and (.model | type == "string")' >/dev/null <<<"$response"; then
    validation_fail "readiness.invalid_response" "Expected done=true and a string model field."
    return 1
  fi
}

warm_ollama_model() {
  local running_models

  if running_models=$(fetch_ollama_running_models) && is_ollama_model_loaded "$running_models"; then
    dbg "Model ${OLLAMA_MODEL} is already loaded; sending a silent readiness ping."
    ping_ollama_model || die "Model ${OLLAMA_MODEL} is already loaded, but the Ollama readiness ping failed."
    return 0
  fi

  dbg "Model ${OLLAMA_MODEL} is not loaded; starting warm-up."
  blocking_status_start "Loading model ${OLLAMA_MODEL}..."
  if ! ping_ollama_model; then
    blocking_status_stop
    die "Failed to load and verify model ${OLLAMA_MODEL}."
  fi
  blocking_status_stop
}

select_ollama_model() {
  if [[ -n "$MODEL_OVERRIDE" ]]; then
    OLLAMA_MODEL="$MODEL_OVERRIDE"
  else
    OLLAMA_MODEL="$DEFAULT_MODEL"
  fi
}

preselect_ollama_model_for_banner() {
  select_ollama_model
}

# ===== UI / Animation Utilities =====
SPINNER_PID=""
LIVE_STATUS_ACTIVE=0
LIVE_STATUS_FRAME=0
LIVE_STATUS_LAST_MSG=""
SCRIPT_START_EPOCH=""
CURRENT_STEP=0
TOTAL_STEPS=6

timer_start() { SCRIPT_START_EPOCH=$(date +%s); }

elapsed_since() {
  local start="$1"
  local now
  now=$(date +%s)
  local diff=$((now - start))
  if [[ "$diff" -ge 60 ]]; then
    printf '%dm%ds' $((diff/60)) $((diff%60))
  else
    printf '%d seconds' "$diff"
  fi
}

spinner_start() {
  local msg="${1:-Processing...}"
  [[ "$IS_TTY" -eq 1 ]] || return 0
  live_status_stop 2>/dev/null || true
  spinner_stop

  local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  printf '\033[?25l\r  %b%s%b %s' "$CYAN" "${chars:0:1}" "$NC" "$msg" >&2
  (
    local i=1 len=${#chars}
    while true; do
      sleep 0.08
      printf '\r  %b%s%b %s' "$CYAN" "${chars:i%len:1}" "$NC" "$msg" >&2
      i=$((i + 1))
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf '\r\033[K\033[?25h' >&2
  fi
}

blocking_status_start() {
  local msg="${1:-Processing...}"
  if [[ "$IS_TTY" -eq 1 ]]; then
    spinner_start "$msg"
  else
    step_info "⟩ ${msg}"
  fi
}

blocking_status_stop() {
  [[ "$IS_TTY" -eq 1 ]] || return 0
  spinner_stop
}

live_status_start() {
  local msg="${1:-Processing...}"
  local plain_msg="${2:-$msg}"
  if [[ "$IS_TTY" -ne 1 ]]; then
    step_info "⟩ ${plain_msg}"
    return 0
  fi

  spinner_stop
  LIVE_STATUS_ACTIVE=1
  LIVE_STATUS_FRAME=0
  printf '\033[?25l' >&2
  live_status_update "$msg"
}

live_status_update() {
  local msg="${1:-Processing...}"
  [[ "$IS_TTY" -eq 1 ]] || return 0
  [[ "$LIVE_STATUS_ACTIVE" -eq 1 ]] || return 0

  local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  local len=${#chars}
  local frame="${chars:LIVE_STATUS_FRAME%len:1}"
  LIVE_STATUS_LAST_MSG="$msg"
  printf '\r  %b%s%b %s\033[K' "$CYAN" "$frame" "$NC" "$msg" >&2
  LIVE_STATUS_FRAME=$((LIVE_STATUS_FRAME + 1))
}

live_status_print_above() {
  local line="$1"
  if [[ "$IS_TTY" -eq 1 && "$LIVE_STATUS_ACTIVE" -eq 1 ]]; then
    printf '\r\033[K' >&2
    echo -e "$line" >&2
    live_status_update "${LIVE_STATUS_LAST_MSG:-Processing...}"
  else
    echo -e "$line" >&2
  fi
}

live_status_stop() {
  [[ "$IS_TTY" -eq 1 ]] || return 0
  [[ "$LIVE_STATUS_ACTIVE" -eq 1 ]] || return 0

  LIVE_STATUS_ACTIVE=0
  LIVE_STATUS_LAST_MSG=""
  printf '\r\033[K\033[?25h' >&2
}

progress_status_text() {
  local current="$1" total="$2" label="${3:-Processing}" elapsed="${4:-}"
  local width=14
  local filled=0 percent=0
  local bar="" i

  if [[ "$total" -gt 0 ]]; then
    filled=$((current * width / total))
    percent=$((current * 100 / total))
  fi

  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=filled; i<width; i++)); do bar+="░"; done

  if [[ -n "$elapsed" ]]; then
    printf '%s [%s] %d/%d %d%% · %s' "$label" "$bar" "$current" "$total" "$percent" "$elapsed"
  else
    printf '%s [%s] %d/%d %d%%' "$label" "$bar" "$current" "$total" "$percent"
  fi
}

show_step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  local label="$1"
  echo -e "${BOLD} [${CURRENT_STEP}/${TOTAL_STEPS}] ${label} ${NC}" >&2
}

step_ok() {
  echo -e "  ${GREEN}✓${NC} $*" >&2
}

step_info() {
  echo -e "  ${DIM}$*${NC}" >&2
}

show_banner() {
  [[ "$NO_BANNER" -eq 1 ]] && return 0
  local repo branch
  repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "?")
  branch=$(git branch --show-current 2>/dev/null || echo "?")
  local model_label="${OLLAMA_MODEL:-$DEFAULT_MODEL}"
  echo -e "${BOLD}git-ai v${VERSION}${NC} — AI Commit Assistant 🤖" >&2
  echo -e "  Model: ${CYAN}${model_label}${NC}" >&2
  echo -e "  Repo:  ${MAGENTA}${repo}${NC} (${branch})" >&2
}

show_summary() {
  local elapsed_text
  elapsed_text=$(elapsed_since "$SCRIPT_START_EPOCH")
  echo -e "${GREEN}✅ Completed in ${elapsed_text}${NC}" >&2
  if [[ -n "${1:-}" ]]; then
    echo -e "  ${DIM}${1}${NC}" >&2
  fi
}

restore_cursor() {
  [[ "$IS_TTY" -eq 1 ]] || return 0
  printf '\033[?25h' >&2
}

show_help() {
  cat <<HELP
Usage: git-ai.sh [OPTIONS]

Auto-stage → AI commit message (Ollama) → commit → push.
Output commit message:
  - Line 1: <type>: <summary> (without a scope)
  - One staged file: no body; multiple files: 1-${MAX_BODY_BULLETS} relevant bullet(s)

Options:
  -h, --help                  Show help
  -v, --version               Show version
  -s, --status                Show Git status only
  -n, --no-push               Commit without pushing
  -m, --model MODEL           Temporarily use an Ollama model for this invocation
  -p, --patch                 Interactive staging (git add -p)
  -i, --interactive           Show the commit message and ask for confirmation before committing
      --no-stage              Do not stage changes automatically
      --dry-run               Only display the commit message (do not change Git state)
      --debug                 Show full commands, Git context, prompts, HTTP responses, and validation details
      --force-diff            Send the diff to AI even when sensitive patterns are detected
      --allow-secret-commit   Allow committing when the scanner finds a potential secret
      --no-file-analysis      Disable per-file analysis (faster)
      --file-analysis-limit N Limit the number of files for per-file analysis (default: ${FILE_ANALYSIS_LIMIT})
      --file-analysis-parallelism N
                              Number of parallel file-analysis requests (default: ${FILE_ANALYSIS_PARALLELISM})
      --no-structured         Disable structured output (fall back to plain text)
      --no-pull               Do not auto-pull a missing model
      --no-banner             Do not show the initial banner
      --no-verify             Commit without running Git hooks (git commit --no-verify)

Config:
  ${SCRIPT_CONFIG_FILE}

Config variables:
  DEFAULT_MODEL               Ollama model used when -m/--model is not specified
  DEFAULT_DO_PUSH             Default push after a commit (0/1, default 1)
  USE_STRUCTURED_OUTPUT       Use Ollama JSON Schema output (0/1, default 1)
  DEFAULT_OLLAMA_HOST         Primary Ollama host (empty = read service)
  FALLBACK_OLLAMA_HOST        Backup host when the primary host is unavailable
  AI_TEMPERATURE              Default ${AI_TEMPERATURE}
  AI_THINK                    Default false (options: false|true|low|medium|high)
  AI_NUM_PREDICT              Output tokens per request (max: ${AI_MAX_NUM_PREDICT})
  AI_MAX_NUM_PREDICT          Maximum num_predict value
  FILE_ANALYSIS_LIMIT         Maximum number of files for per-file analysis
  FILE_ANALYSIS_NUM_PREDICT_PER_FILE
                              Output tokens per file analysis (default: ${FILE_ANALYSIS_NUM_PREDICT_PER_FILE})
  FILE_ANALYSIS_PARALLELISM   Number of parallel file-analysis requests (default: ${FILE_ANALYSIS_PARALLELISM})
  MAX_FILES_LIST              Maximum number of files in the Git name/status context
  TOP_FILES                   Number of largest files summarized by hunks
  MAX_HUNK_CHARS              Maximum hunk characters per file
  MAX_TOTAL_HUNKS_CHARS       Maximum total hunk characters sent to AI
  MAX_COMMIT_MESSAGE_LENGTH   Maximum complete commit-message length (default: ${MAX_COMMIT_MESSAGE_LENGTH})

Ollama service:
  ${OLLAMA_SERVICE_FILE} is used when DEFAULT_OLLAMA_HOST is empty.
HELP
}

set_model_override() {
  local model="${1:-}"

  [[ -n "$model" ]] || die "-m/--model requires a non-empty model name"
  [[ "$model" != -* ]] || die "-m/--model requires a model name, not another option"
  [[ "$model" != *[[:space:]]* ]] || die "-m/--model does not allow whitespace in the model name"

  MODEL_OVERRIDE="$model"
  select_ollama_model
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)            show_help; exit 0 ;;
      -v|--version)         echo "git-ai version $VERSION"; exit 0 ;;
      -s|--status)          check_git_repo; git status; exit 0 ;;
      -n|--no-push)         DO_PUSH=0; shift ;;
      -m|--model)           [[ $# -ge 2 ]] || die "$1 requires a model name"
                            set_model_override "$2"; shift 2 ;;
      --model=*)            set_model_override "${1#*=}"; shift ;;
      -p|--patch)           USE_PATCH=1; shift ;;
      -i|--interactive)     INTERACTIVE=1; shift ;;
      --no-stage)           DO_STAGE=0; shift ;;
      --dry-run)            DRY_RUN=1; shift ;;
      --debug)              DEBUG=1; shift ;;
      --force-diff)         FORCE_DIFF=1; shift ;;
      --allow-secret-commit) ALLOW_SECRET_COMMIT=1; shift ;;
      --no-file-analysis)   DO_FILE_ANALYSIS=0; shift ;;
      --file-analysis-limit)
                            [[ $# -ge 2 ]] || die "--file-analysis-limit requires a number"
                            [[ "$2" =~ ^[0-9]+$ ]] || die "--file-analysis-limit must be a non-negative number"
                            FILE_ANALYSIS_LIMIT="$2"; shift 2 ;;
      --file-analysis-parallelism)
                            [[ $# -ge 2 ]] || die "--file-analysis-parallelism requires a number"
                            [[ "$2" =~ ^[0-9]+$ ]] || die "--file-analysis-parallelism must be a number >= 1"
                            [[ "$2" -ge 1 ]] || die "--file-analysis-parallelism must be a number >= 1"
                            FILE_ANALYSIS_PARALLELISM="$2"; shift 2 ;;
      --no-structured)      USE_STRUCTURED_OUTPUT=0; shift ;;
      --no-pull)            NO_PULL=1; shift ;;
      --no-banner)          NO_BANNER=1; shift ;;
      --no-verify)          NO_VERIFY=1; shift ;;
      *)                    die "Unknown option: $1" ;;
    esac
  done
}

check_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not a Git repository"
}

setup_dry_run_index() {
  [[ "$DRY_RUN" -eq 1 ]] || return 0

  local real_index
  real_index=$(git rev-parse --git-path index)

  DRY_RUN_INDEX_FILE=$(mktemp)
  if [[ -f "$real_index" ]]; then
    cp "$real_index" "$DRY_RUN_INDEX_FILE"
  else
    rm -f "$DRY_RUN_INDEX_FILE"
  fi

  export GIT_INDEX_FILE="$DRY_RUN_INDEX_FILE"
  dbg "Dry-run index enabled: $DRY_RUN_INDEX_FILE"
}

cleanup_dry_run_index() {
  if [[ -n "${DRY_RUN_INDEX_FILE:-}" ]]; then
    rm -f "$DRY_RUN_INDEX_FILE" || true
    unset GIT_INDEX_FILE || true
    DRY_RUN_INDEX_FILE=""
  fi
}

check_deps() {
  show_step "Checking dependencies"

  for cmd in git curl jq flock; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' was not found. Install it first."
  done
  step_ok "git, curl, jq, and flock are available"

  if [[ ! "$DO_PUSH" =~ ^[01]$ ]]; then
    die "DEFAULT_DO_PUSH must be 0 or 1."
  fi
  if [[ ! "$USE_STRUCTURED_OUTPUT" =~ ^[01]$ ]]; then
    die "USE_STRUCTURED_OUTPUT must be 0 or 1."
  fi
  if [[ ! "$FILE_ANALYSIS_LIMIT" =~ ^[0-9]+$ ]] || [[ "$FILE_ANALYSIS_LIMIT" -lt 0 ]]; then
    die "FILE_ANALYSIS_LIMIT must be a non-negative number."
  fi
  if [[ ! "$FILE_ANALYSIS_NUM_PREDICT_PER_FILE" =~ ^[0-9]+$ ]] || [[ "$FILE_ANALYSIS_NUM_PREDICT_PER_FILE" -lt 1 ]]; then
    die "FILE_ANALYSIS_NUM_PREDICT_PER_FILE must be a number >= 1."
  fi
  if [[ ! "$FILE_ANALYSIS_PARALLELISM" =~ ^[0-9]+$ ]] || [[ "$FILE_ANALYSIS_PARALLELISM" -lt 1 ]]; then
    die "FILE_ANALYSIS_PARALLELISM must be a number >= 1."
  fi
  if [[ -n "$AI_NUM_PREDICT" ]] && [[ ! "$AI_NUM_PREDICT" =~ ^[0-9]+$ ]]; then
    die "AI_NUM_PREDICT must be a number."
  fi
  if [[ ! "$AI_MAX_NUM_PREDICT" =~ ^[0-9]+$ ]] || [[ "$AI_MAX_NUM_PREDICT" -lt 1 ]]; then
    die "AI_MAX_NUM_PREDICT must be a number >= 1."
  fi
  if [[ -n "$AI_NUM_PREDICT" && "$AI_NUM_PREDICT" -gt "$AI_MAX_NUM_PREDICT" ]]; then
    warn "AI_NUM_PREDICT exceeds ${AI_MAX_NUM_PREDICT}; using the maximum."
    AI_NUM_PREDICT="$AI_MAX_NUM_PREDICT"
  fi
  if [[ "$FILE_ANALYSIS_NUM_PREDICT_PER_FILE" -gt "$AI_MAX_NUM_PREDICT" ]]; then
    warn "FILE_ANALYSIS_NUM_PREDICT_PER_FILE exceeds ${AI_MAX_NUM_PREDICT}; using the maximum."
    FILE_ANALYSIS_NUM_PREDICT_PER_FILE="$AI_MAX_NUM_PREDICT"
  fi
  if [[ ! "$AI_TEMPERATURE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    die "AI_TEMPERATURE must be a number (for example, 0.2)."
  fi
  if [[ ! "$AI_THINK" =~ ^(false|true|low|medium|high)$ ]]; then
    die "AI_THINK must be one of: false, true, low, medium, high."
  fi
  if [[ ! "$MAX_COMMIT_MESSAGE_LENGTH" =~ ^[0-9]+$ ]] || [[ "$MAX_COMMIT_MESSAGE_LENGTH" -lt 24 ]]; then
    die "MAX_COMMIT_MESSAGE_LENGTH must be a number >= 24."
  fi

  local tags_json primary_url fallback_url
  primary_url="$OLLAMA_BASE_URL"

  spinner_start "Contacting Ollama at ${primary_url}..."
  if tags_json=$(fetch_ollama_tags "$primary_url"); then
    spinner_stop
  else
    spinner_stop
    if fallback_url=$(resolve_ollama_fallback_url) && [[ "$fallback_url" != "$primary_url" ]]; then
      warn "Ollama is unavailable at $primary_url. Trying fallback $fallback_url..."
      spinner_start "Contacting fallback Ollama at ${fallback_url}..."
      if tags_json=$(fetch_ollama_tags "$fallback_url"); then
        spinner_stop
        OLLAMA_BASE_URL="$fallback_url"
        refresh_ollama_urls
        step_info "Fallback Ollama host enabled: ${OLLAMA_BASE_URL}"
      else
        spinner_stop
        die "Ollama is unavailable at $primary_url or fallback $fallback_url (tags). Ensure the service is running."
      fi
    else
      die "Ollama is unavailable at $primary_url (tags). Ensure the service is running and ${SCRIPT_CONFIG_FILE} or ${OLLAMA_SERVICE_FILE} is correct."
    fi
  fi
  step_info "Active Ollama host: ${OLLAMA_BASE_URL}"

  local available_models
  available_models=$(jq -r '.models[].name' <<<"$tags_json" 2>/dev/null | sed '/^$/d' || true)

  select_ollama_model
  if [[ -n "$MODEL_OVERRIDE" ]]; then
    step_info "Model from -m/--model: ${OLLAMA_MODEL}"
  else
    step_info "Model from DEFAULT_MODEL: ${OLLAMA_MODEL}"
  fi

  if ! printf '%s\n' "$available_models" | grep -Fxq -- "$OLLAMA_MODEL"; then
    warn "Selected model '$OLLAMA_MODEL' was not found."

    if [[ "$NO_PULL" -eq 1 ]]; then
      die "Model '$OLLAMA_MODEL' is not on the server and --no-pull is enabled. Pull it first: ollama pull $OLLAMA_MODEL"
    fi
    if command -v ollama >/dev/null 2>&1; then
      warn "Pulling selected model: $OLLAMA_MODEL..."
      dbg "Command: OLLAMA_HOST=${OLLAMA_BASE_URL} ollama pull ${OLLAMA_MODEL}"
      OLLAMA_HOST="$OLLAMA_BASE_URL" ollama pull "$OLLAMA_MODEL"
    else
      die "Model '$OLLAMA_MODEL' is not on the server and the 'ollama' CLI was not found to pull it."
    fi
  fi
  warm_ollama_model
}

has_any_changes() {
  ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]
}

has_staged_changes() {
  ! git diff --cached --quiet
}

stage_changes() {
  show_step "Staging changes"

  if ! has_any_changes; then
    warn "No changes to commit."
    exit 0
  fi

  if [[ "$DO_STAGE" -eq 0 ]]; then
    if ! has_staged_changes; then
      die "You selected --no-stage, but there are no staged changes. Run git add first."
    fi
    step_ok "Using existing staged changes"
    dbg_command_output "git diff --cached --name-status -M" "$(git diff --cached --name-status -M 2>&1 || true)"
    enforce_staged_secret_policy
    return 0
  fi

  if [[ "$USE_PATCH" -eq 1 ]]; then
    dbg "Command: git add -p"
    git add -p
  else
    blocking_status_start "Scanning, hashing, and staging working-tree changes..."
    dbg "Command: git add -A"
    if ! git add -A; then
      blocking_status_stop
      die "Failed to stage changes."
    fi
    blocking_status_stop
  fi

  if ! has_staged_changes; then
    warn "No staged changes after staging."
    exit 0
  fi

  local staged_count
  staged_count=$(git diff --cached --name-only | wc -l)
  local stage_method="git add -A"
  [[ "$USE_PATCH" -eq 1 ]] && stage_method="git add -p"
  step_ok "${staged_count} file(s) staged (${stage_method})"
  dbg_command_output "git diff --cached --name-status -M" "$(git diff --cached --name-status -M 2>&1 || true)"

  enforce_staged_secret_policy
}

sensitive_pattern_regex() {
  cat <<'EOF'
(([A-Za-z0-9_.-]*(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|private[_-]?key|client[_-]?secret)[A-Za-z0-9_.-]*)[[:space:]]*[:=][[:space:]]*['"]?[A-Za-z0-9_./+=:@-]{12,}['"]?|BEGIN [A-Z]+ PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pous]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})
EOF
}

has_sensitive_patterns() {
  local content="$1"
  grep -Eiq "$(sensitive_pattern_regex)" <<<"$content"
}

detect_sensitive_patterns() {
  local sample
  sample=$(git diff --cached --no-color --no-ext-diff || true)

  has_sensitive_patterns "$sample"
}

is_secret_placeholder_line() {
  local content="$1"
  local lower
  lower=$(printf '%s' "$content" | tr '[:upper:]' '[:lower:]')

  grep -Eiq '(placeholder|changeme|change_me|change-me|dummy|sample|example|your[-_ ]?[a-z0-9_-]*|<[^>]+>|\$\{|\{\{[[:space:]]*secrets\.)' <<<"$lower"
}

detect_staged_secret_lines() {
  local current_file="?"
  local new_line=0
  local line content line_no

  while IFS= read -r line; do
    case "$line" in
      "+++ b/"*)
        current_file="${line#+++ b/}"
        ;;
      "+++ /dev/null")
        current_file="?"
        ;;
      @@*)
        if [[ "$line" =~ \+([0-9]+)(,[0-9]+)?[[:space:]]@@ ]]; then
          new_line="${BASH_REMATCH[1]}"
        else
          new_line=0
        fi
        ;;
      +*)
        [[ "$line" == "+++"* ]] && continue
        content="${line#+}"
        if has_sensitive_patterns "$content" && ! is_secret_placeholder_line "$content"; then
          line_no="$new_line"
          if ! [[ "$line_no" =~ ^[0-9]+$ ]] || ! [[ "$line_no" -gt 0 ]]; then
            line_no="?"
          fi
          printf '%s:%s potential secret on added line\n' "$current_file" "$line_no"
        fi
        if [[ "$new_line" =~ ^[0-9]+$ ]] && [[ "$new_line" -gt 0 ]]; then
          new_line=$((new_line + 1))
        fi
        ;;
      -*)
        ;;
      *)
        if [[ "$new_line" =~ ^[0-9]+$ ]] && [[ "$new_line" -gt 0 ]]; then
          new_line=$((new_line + 1))
        fi
        ;;
    esac
  done < <(git diff --cached --no-color --unified=0 --no-ext-diff || true)
}

run_gitleaks_secret_scan() {
  command -v gitleaks >/dev/null 2>&1 || return 1

  local out status
  dbg "Command: gitleaks protect --staged --redact --no-banner"
  set +e
  out=$(gitleaks protect --staged --redact --no-banner 2>&1)
  status=$?
  set -e
  dbg "Command exit status: ${status}"
  dbg_block "Command output: gitleaks protect --staged --redact --no-banner" "$out"

  [[ "$status" -eq 0 ]] && return 1
  if grep -Eiq '(leak|leaks|secret|finding|RuleID|Fingerprint)' <<<"$out"; then
    printf 'gitleaks found a potential secret in staged changes\n'
    return 0
  fi

  dbg "gitleaks scan skipped/failed compatibility check: $(printf '%s' "$out" | head -c 300)"
  return 1
}

enforce_staged_secret_policy() {
  local report external_report

  blocking_status_start "Scanning staged changes for potential secrets..."
  report=$(detect_staged_secret_lines || true)
  external_report=$(run_gitleaks_secret_scan || true)
  blocking_status_stop

  if [[ -n "$external_report" ]]; then
    [[ -n "$report" ]] && report+=$'\n'
    report+="$external_report"
  fi

  [[ -n "$report" ]] || return 0

  warn "Potential secrets detected in staged changes:"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    warn "  - $line"
  done < <(printf '%s\n' "$report" | head -n 20)

  local total_lines
  total_lines=$(printf '%s\n' "$report" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')
  if [[ "$total_lines" -gt 20 ]]; then
    warn "  ... $((total_lines - 20)) additional findings hidden"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "DRY RUN: the commit would be blocked normally, but dry-run continues without commit/push."
    return 0
  fi

  if [[ "$ALLOW_SECRET_COMMIT" -eq 1 ]]; then
    warn "Secret commit allowed by --allow-secret-commit. Safe mode remains active unless --force-diff is used."
    return 0
  fi

  die "Commit cancelled to prevent a secret from being committed. Remove the secret or use --allow-secret-commit only when intentional."
}

collect_top_files() {
  local tmp generated_tmp source_file
  tmp=$(mktemp)
  generated_tmp=$(mktemp)
  # Ensure the temporary file is removed even if this function fails midway.
  trap 'rm -f "$tmp" "$generated_tmp"' RETURN
  while IFS=$'\t' read -r add del path; do
    [[ -z "${path:-}" ]] && continue
    [[ "${add:-0}" == "-" ]] && add=0
    [[ "${del:-0}" == "-" ]] && del=0
    local total=$((add + del))
    if is_generated_path "$path"; then
      printf "%s\t%s\n" "$total" "$path" >> "$generated_tmp"
    else
      printf "%s\t%s\n" "$total" "$path" >> "$tmp"
    fi
  done < <(git diff --cached --numstat || true)

  source_file="$tmp"
  [[ -s "$source_file" ]] || source_file="$generated_tmp"
  sort -nrk1,1 "$source_file" | head -n "$TOP_FILES" | cut -f2- || true
}

collect_top_hunks() {
  local total_chars=0
  local out=""

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local piece
    piece=$(git diff --cached --no-color --unified=2 -- "$f" 2>/dev/null || true)
    [[ -z "$piece" ]] && continue

    piece=$(echo "$piece" | head -c "$MAX_HUNK_CHARS")

    local next_total=$((total_chars + ${#piece}))
    [[ "$next_total" -gt "$MAX_TOTAL_HUNKS_CHARS" ]] && break

    out+=$'\n'"### File: $f"$'\n'
    out+="$piece"$'\n'
    total_chars=$next_total
  done < <(collect_top_files)

  echo "$out"
}

collect_priority_changes() {
  local out="" generated_out="" entry status path1 path2

  while IFS=$'\t' read -r status path1 path2; do
    [[ -z "${status:-}" || -z "${path1:-}" ]] && continue

    case "$status" in
      R*) entry="Rename: ${path1} -> ${path2}" ;;
      C*) entry="Copy: ${path1} -> ${path2}" ;;
      D)  entry="Delete: ${path1}" ;;
      A)  entry="Add: ${path1}" ;;
      M)  entry="Modify: ${path1}" ;;
      *)  entry="${status}: ${path1}" ;;
    esac

    if is_generated_path "${path2:-$path1}"; then
      generated_out+="$entry"$'\n'
    else
      out+="$entry"$'\n'
    fi
  done < <(git diff --cached --name-status -M || true)

  [[ -n "$out" ]] || out="$generated_out"
  printf '%s' "$out" | head -n "$MAX_FILES_LIST" || true
}

collect_diff_terms() {
  git diff --cached --no-color --unified=0 2>/dev/null \
    | head -c 30000 \
    | grep -E '^[+-]' \
    | grep -Ev '^(---|\+\+\+)' \
    | grep -Eo '[A-Z][A-Z0-9_]{2,}|[A-Za-z0-9_-]+\.(service|env|conf|config|ini|sh|md|py|js|jsx|ts|tsx|go|rs|java|kt|php|rb|sql|graphql|proto|json|toml|ya?ml|xml)|[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+' \
    | sort -u \
    | head -n 16 \
    | tr '\n' ', ' \
    | sed 's/, $//' || true
}

add_change_focus_term() {
  local term="$1"
  term=$(printf '%s' "$term" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [[ -n "$term" ]] || return 0
  [[ "${#term}" -ge 3 ]] || return 0

  case "${term,,}" in
    src|lib|app|bin|cmd|pkg|test|tests|spec|docs|doc|the|and|file|utils)
      return 0
      ;;
  esac

  if ! grep -Fxq -- "$term" <<<"${CHANGE_FOCUS_TERMS:-}"; then
    CHANGE_FOCUS_TERMS+="$term"$'\n'
  fi
}

add_path_focus_terms() {
  local path="$1"
  local base stem part

  [[ -n "$path" ]] || return 0
  base="${path##*/}"
  stem="${base%.*}"

  add_change_focus_term "$base"
  add_change_focus_term "$stem"

  while IFS= read -r part; do
    add_change_focus_term "$part"
    case "${part,,}" in
      *model*) add_change_focus_term "model" ;;
      *service*) add_change_focus_term "service" ;;
      *config*) add_change_focus_term "configuration" ;;
      *schema*) add_change_focus_term "schema" ;;
      *migration*) add_change_focus_term "migration" ;;
    esac
  done < <(printf '%s\n' "$path" | tr '/._-' '\n' | sed '/^$/d')
}

path_subject_label() {
  local path="$1"
  local base stem first second

  base="${path##*/}"
  stem="${base%.*}"
  first=$(printf '%s' "$stem" | tr '._-' ' ' | awk '{print $1}')
  second=$(printf '%s' "$stem" | tr '._-' ' ' | awk '{print $2}')

  if [[ -n "$first" && -n "$second" && "$first" =~ ^[Mm]odel ]]; then
    printf '%s %s' "$first" "$second"
  elif [[ -n "$first" ]]; then
    printf '%s' "$first"
  else
    printf '%s' "$base"
  fi
}

is_doc_path() {
  local path="${1,,}"
  [[ "$path" =~ (^|/)(docs?|readme|changelog|license|ag.?ents)(/|\.|$) || "$path" =~ \.(md|rst|txt|adoc)$ ]]
}

is_config_path() {
  local path="${1,,}"
  [[ "$path" =~ \.(service|env|conf|config|ini|toml|ya?ml|json|lock)$ || "$path" =~ (^|/)(dockerfile|compose|nginx|systemd|k8s|helm|terraform|ansible|ci|cd|workflow|workflows|package\.json|pyproject\.toml|cargo\.toml)(/|$) ]]
}

is_schema_api_db_path() {
  local path="${1,,}"
  [[ "$path" =~ (^|/)(migrations?|schema|schemas|prisma|database|db|sql|api|routes?|proto|graphql|openapi|swagger)(/|\.|$) || "$path" =~ \.(sql|graphql|proto)$ ]]
}

is_code_path() {
  local path="${1,,}"
  [[ "$path" =~ \.(py|js|jsx|ts|tsx|go|rs|java|kt|php|rb|cs|cpp|c|h|swift|scala|sh|bash|zsh)$ ]]
}

is_generated_path() {
  local path="${1,,}"
  [[ "$path" =~ (^|/)(generated|__generated__|codegen|vendor)(/|$) || "$path" =~ \.(generated|gen)\.[^.]+$ ]]
}

is_test_path() {
  local path="${1,,}"
  [[ "$path" =~ (^|/)(test|tests|spec|specs)(/|\.|$) || "$path" =~ (\.test|\.spec|_test)\.[^.]+$ ]]
}

is_frontend_path() {
  local path="${1,,}"
  [[ "$path" =~ (^|/)(frontend|client|web)(/|$) || "$path" =~ \.(jsx|tsx|vue|svelte)$ ]]
}

is_api_path() {
  local path="${1,,}"
  [[ "$path" =~ (^|/)(api|apis|routes?|endpoints?)(/|\.|$) ]]
}

is_database_path() {
  local path="${1,,}"
  [[ "$path" =~ (^|/)(migrations?|models?|schema|schemas|database|db|sql)(/|\.|$) || "$path" =~ \.(sql|prisma)$ ]]
}

is_security_path() {
  local path="${1,,}"
  [[ "$path" =~ (capabilit|permission|authoriz|auth|csrf|security|middleware) ]]
}

classify_change_context() {
  local status path1 path2 path

  HAS_DELETE=0
  HAS_RENAME=0
  HAS_CONFIG_CHANGE=0
  HAS_SCHEMA_API_DB_CHANGE=0
  HAS_CODE_CHANGE=0
  HAS_DOC_CHANGE=0
  HAS_GENERATED_CHANGE=0
  HAS_API_CHANGE=0
  HAS_DATABASE_CHANGE=0
  HAS_SECURITY_CHANGE=0
  HAS_FRONTEND_CHANGE=0
  HAS_TEST_CHANGE=0
  HAS_FUNCTIONAL_CHANGE=0
  GENERATED_FILE_COUNT=0
  FUNCTIONAL_FILE_COUNT=0
  DELETE_FOCUS_LABEL=""
  RENAME_FOCUS_LABEL=""
  CHANGE_FOCUS_TERMS=""

  while IFS=$'\t' read -r status path1 path2; do
    [[ -z "${status:-}" || -z "${path1:-}" ]] && continue

    case "$status" in
      R*)
        HAS_RENAME=1
        path="${path2:-$path1}"
        [[ -n "$RENAME_FOCUS_LABEL" ]] || RENAME_FOCUS_LABEL=$(path_subject_label "$path")
        ;;
      D)
        HAS_DELETE=1
        path="$path1"
        [[ -n "$DELETE_FOCUS_LABEL" ]] || DELETE_FOCUS_LABEL=$(path_subject_label "$path")
        ;;
      A)
        path="$path1"
        ;;
      *)
        path="$path1"
        ;;
    esac

    if is_generated_path "$path"; then
      HAS_GENERATED_CHANGE=1
      GENERATED_FILE_COUNT=$((GENERATED_FILE_COUNT + 1))
      continue
    fi

    if [[ "$status" == R* ]]; then
      add_path_focus_terms "$path1"
      add_path_focus_terms "$path"
    else
      add_path_focus_terms "$path"
    fi

    is_doc_path "$path" && HAS_DOC_CHANGE=1
    is_config_path "$path" && HAS_CONFIG_CHANGE=1
    is_schema_api_db_path "$path" && HAS_SCHEMA_API_DB_CHANGE=1
    is_code_path "$path" && HAS_CODE_CHANGE=1
    is_api_path "$path" && HAS_API_CHANGE=1
    is_database_path "$path" && HAS_DATABASE_CHANGE=1
    is_security_path "$path" && HAS_SECURITY_CHANGE=1
    is_frontend_path "$path" && HAS_FRONTEND_CHANGE=1
    is_test_path "$path" && HAS_TEST_CHANGE=1

    if is_code_path "$path" || is_api_path "$path" || is_database_path "$path" || is_security_path "$path" || is_frontend_path "$path"; then
      HAS_FUNCTIONAL_CHANGE=1
      FUNCTIONAL_FILE_COUNT=$((FUNCTIONAL_FILE_COUNT + 1))
    fi
  done < <(git diff --cached --name-status -M || true)

  local term
  while IFS= read -r term; do
    add_change_focus_term "$term"
  done < <(printf '%s\n' "${DIFF_TERMS:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d')
}

build_semantic_change_summary() {
  local functional=()
  local supporting=()

  [[ "${HAS_DATABASE_CHANGE:-0}" -eq 1 ]] && functional+=("data model, migrations, or database integrity")
  [[ "${HAS_API_CHANGE:-0}" -eq 1 ]] && functional+=("API or endpoint behavior")
  [[ "${HAS_SECURITY_CHANGE:-0}" -eq 1 ]] && functional+=("authorization, permissions, or request security")
  [[ "${HAS_FRONTEND_CHANGE:-0}" -eq 1 ]] && functional+=("frontend integration or user flow")
  [[ "${HAS_CONFIG_CHANGE:-0}" -eq 1 ]] && functional+=("runtime or service behavior")
  [[ "${HAS_DELETE:-0}" -eq 1 || "${HAS_RENAME:-0}" -eq 1 ]] && functional+=("structural cleanup or relocation")
  [[ "${HAS_TEST_CHANGE:-0}" -eq 1 ]] && supporting+=("test coverage")
  [[ "${HAS_DOC_CHANGE:-0}" -eq 1 ]] && supporting+=("documentation")
  if [[ "${HAS_GENERATED_CHANGE:-0}" -eq 1 ]]; then
    supporting+=("${GENERATED_FILE_COUNT} generated artifact(s), which must not lead the subject when functional changes exist")
  fi

  if [[ "${#functional[@]}" -gt 0 ]]; then
    printf 'Functional themes to prioritize:\n'
    printf '%s\n' "${functional[@]}"
  fi
  if [[ "${#supporting[@]}" -gt 0 ]]; then
    printf 'Supporting themes:\n'
    printf '%s\n' "${supporting[@]}"
  fi
  if [[ "${#functional[@]}" -eq 0 && "${#supporting[@]}" -eq 0 ]]; then
    printf 'No semantic category was inferred; use the most concrete changed domain term.'
  fi
}

build_change_priority_hint() {
  local hints=()

  [[ "${HAS_DATABASE_CHANGE:-0}" -eq 1 ]] && hints+=("data model, migration, or database integrity")
  [[ "${HAS_API_CHANGE:-0}" -eq 1 ]] && hints+=("API or endpoint behavior")
  [[ "${HAS_SECURITY_CHANGE:-0}" -eq 1 ]] && hints+=("authorization, permissions, or request security")
  [[ "${HAS_FRONTEND_CHANGE:-0}" -eq 1 ]] && hints+=("frontend integration or user flow")
  [[ "${HAS_CONFIG_CHANGE:-0}" -eq 1 ]] && hints+=("runtime or service behavior")
  [[ "${HAS_DELETE:-0}" -eq 1 || "${HAS_RENAME:-0}" -eq 1 ]] && hints+=("structural cleanup or relocation")
  [[ "${HAS_TEST_CHANGE:-0}" -eq 1 ]] && hints+=("tests")
  [[ "${HAS_DOC_CHANGE:-0}" -eq 1 ]] && hints+=("documentation")
  [[ "${HAS_GENERATED_CHANGE:-0}" -eq 1 ]] && hints+=("generated artifacts (supporting only)")

  if [[ "${#hints[@]}" -eq 0 ]]; then
    printf 'staged file changes'
  else
    printf '%s\n' "${hints[@]}"
  fi
}

collect_context() {
  local safe_mode="${1:-0}"

  STAGED_FILE_COUNT=$(git diff --cached --name-only | wc -l | tr -d '[:space:]')

  NAME_STATUS=$(git diff --cached --name-status -M | head -n "$MAX_FILES_LIST" || true)
  STAT=$(git diff --cached --stat | head -n "$MAX_FILES_LIST" || true)
  GIT_PRIORITY_CHANGES=$(collect_priority_changes)
  GIT_SUMMARY=$(git diff --cached --summary -M | head -n "$MAX_FILES_LIST" || true)
  if [[ "$safe_mode" -eq 1 ]]; then
    DIFF_TERMS=""
  else
    DIFF_TERMS=$(collect_diff_terms)
  fi
  classify_change_context
  SEMANTIC_CHANGE_SUMMARY=$(build_semantic_change_summary)
  CHANGE_PRIORITY_HINT=$(build_change_priority_hint)
  FILES_CHANGED=$(git diff --cached --name-only | head -n "$MAX_FILES_LIST" | tr '\n' ', ' | sed 's/, $//' || true)
  if [[ "$safe_mode" -eq 1 ]]; then
    TOP_HUNKS=""
  else
    TOP_HUNKS=$(collect_top_hunks)
  fi
}

debug_git_context() {
  local safe_mode="$1"

  [[ "${DEBUG}" -eq 1 ]] || return 0

  local status_output name_status_output stat_output summary_output full_diff_output
  status_output=$(git status --short 2>&1 || true)
  name_status_output=$(git diff --cached --name-status -M 2>&1 || true)
  stat_output=$(git diff --cached --stat 2>&1 || true)
  summary_output=$(git diff --cached --summary -M 2>&1 || true)

  dbg_command_output "git status --short" "$status_output"
  dbg_command_output "git diff --cached --name-status -M" "$name_status_output"
  dbg_command_output "git diff --cached --stat" "$stat_output"
  dbg_command_output "git diff --cached --summary -M" "$summary_output"

  if [[ "$safe_mode" -eq 1 && "$FORCE_DIFF" -eq 0 ]]; then
    dbg "Command skipped: git diff --cached --no-color --no-ext-diff"
    dbg_block "Full staged diff" "<omitted: safe mode detected sensitive content>"
  else
    full_diff_output=$(git diff --cached --no-color --no-ext-diff 2>&1 || true)
    dbg_command_output "git diff --cached --no-color --no-ext-diff" "$full_diff_output"
  fi

  dbg_block "Collected Git priority changes" "${GIT_PRIORITY_CHANGES:-}"
  dbg_block "Collected semantic change summary" "${SEMANTIC_CHANGE_SUMMARY:-}"
  dbg_block "Collected change priority hint" "${CHANGE_PRIORITY_HINT:-}"
}

# ===== Per-File Analysis =====
SYSTEM_PROMPT_FILE_ANALYSIS_BATCH='You are a Git diff analyst. Analyze each file separately in English. Output valid JSON that conforms to the schema. For each file, set "file" to the exact input filename and provide one or two clear sentences covering the behavior, domain capability, or user-facing impact added by the diff. Treat generated files as supporting artifacts, not primary features. Do not use Markdown, summarize only file names, or give generic answers.'

split_diff_to_chunks() {
  local diff_content="$1"
  DIFF_CHUNKS=()
  local chunk=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^diff\ --git\  ]]; then
      if [[ -n "$chunk" ]]; then
        DIFF_CHUNKS+=("$chunk")
      fi
      chunk="$line"$'\n'
    else
      chunk+="$line"$'\n'
    fi
  done <<< "$diff_content"
  [[ -n "$chunk" ]] && DIFF_CHUNKS+=("$chunk")
}

diff_chunk_file_name() {
  local chunk="$1"
  printf '%s\n' "$chunk" | head -n 1 | sed -e 's#.* b/##'
}

add_analysis_index() {
  local idx="$1"
  local total="$2"
  local existing

  [[ "$idx" -lt 1 ]] && idx=1
  [[ "$idx" -gt "$total" ]] && idx="$total"

  for existing in "${ANALYSIS_INDICES[@]}"; do
    [[ "$existing" -eq "$idx" ]] && return 0
  done

  ANALYSIS_INDICES+=("$idx")
}

fraction_index() {
  local total="$1"
  local numerator="$2"
  local denominator="$3"
  local idx

  idx=$(((total * numerator + denominator / 2) / denominator))
  [[ "$idx" -lt 1 ]] && idx=1
  [[ "$idx" -gt "$total" ]] && idx="$total"
  printf '%s' "$idx"
}

build_analysis_indices() {
  local total="$1"
  local limit="$2"
  local i idx

  ANALYSIS_INDICES=()

  if [[ "$total" -le "$limit" ]]; then
    for ((i=1; i<=total; i++)); do
      add_analysis_index "$i" "$total"
    done
  elif [[ "$limit" -eq 1 ]]; then
    add_analysis_index 1 "$total"
  elif [[ "$limit" -eq 6 ]]; then
    add_analysis_index 1 "$total"
    add_analysis_index "$(fraction_index "$total" 1 3)" "$total"
    add_analysis_index "$(fraction_index "$total" 1 2)" "$total"
    add_analysis_index "$(fraction_index "$total" 2 3)" "$total"
    add_analysis_index "$(fraction_index "$total" 5 6)" "$total"
    add_analysis_index "$total" "$total"
  else
    for ((i=0; i<limit; i++)); do
      idx=$((1 + (i * (total - 1) + (limit - 1) / 2) / (limit - 1)))
      add_analysis_index "$idx" "$total"
    done
  fi

  i=1
  while [[ "${#ANALYSIS_INDICES[@]}" -lt "$limit" && "$i" -le "$total" ]]; do
    add_analysis_index "$i" "$total"
    i=$((i + 1))
  done

  printf '%s\n' "${ANALYSIS_INDICES[@]}"
}

build_file_analysis_batch_schema() {
  jq -n '
    {
      type: "object",
      additionalProperties: false,
      properties: {
        files: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              file: {type: "string"},
              analysis: {type: "string"}
            },
            required: ["file", "analysis"]
          }
        }
      },
      required: ["files"]
    }
  '
}

build_file_analysis_batch_prompt() {
  local start="$1"
  local count="$2"
  local end=$((start + count))
  local i prompt

  prompt='Analyze the following diff one file at a time. Return JSON with a "files" array in the input order. Include exactly one item for every [FILE]. Make each analysis specific to the diff, not a generic response.'

  for ((i=start; i<end; i++)); do
    prompt+=$'\n\n[FILE]\n'"${BATCH_ANALYSIS_FILE_NAMES[$i]}"
    prompt+=$'\n[DIFF]\n'"${BATCH_ANALYSIS_DIFF_CHUNKS[$i]}"$'\n[/DIFF]'
  done

  printf '%s' "$prompt"
}

run_file_analysis_batch() {
  local batch_no="$1"
  local start="$2"
  local count="$3"
  local output_file="$4"

  local schema prompt content json batch_num_predict
  schema=$(build_file_analysis_batch_schema)
  prompt=$(build_file_analysis_batch_prompt "$start" "$count")
  batch_num_predict=$((count * FILE_ANALYSIS_NUM_PREDICT_PER_FILE + 120))
  [[ "$batch_num_predict" -lt 360 ]] && batch_num_predict=360

  if ! content=$(ollama_chat "$SYSTEM_PROMPT_FILE_ANALYSIS_BATCH" "$prompt" "$schema" 60 1 "$batch_num_predict"); then
    dbg "Analysis batch ${batch_no} failed [analysis.request_failed]; using per-file fallback."
  elif ! json=$(printf '%s' "$content" | jq -e . 2>/dev/null); then
    dbg "Analysis batch ${batch_no} failed [analysis.invalid_json]; using per-file fallback."
  elif ! jq -e '(.files | type == "array") and all(.files[]?; (.file | type == "string") and (.analysis | type == "string"))' >/dev/null <<<"$json"; then
    dbg "Analysis batch ${batch_no} failed [analysis.invalid_fields]; using per-file fallback."
  else
    printf '%s\n' "$json" > "$output_file"
    dbg "Analysis batch ${batch_no} completed (${count} file(s))"
    return 0
  fi

  printf '{"files":[]}\n' > "$output_file"
  return 1
}

extract_file_analysis_from_batch() {
  local output_file="$1"
  local file_name="$2"

  jq -r --arg file "$file_name" \
    '[.files[]? | select(.file == $file) | .analysis][0] // empty' \
    "$output_file" 2>/dev/null | head -n 1 || true
}

analyze_files_individually() {
  local full_diff
  full_diff=$(git diff --cached --no-color -U3 || true)
  [[ -z "$full_diff" ]] && return 1

  split_diff_to_chunks "$full_diff"

  local total_files=${#DIFF_CHUNKS[@]}
  [[ "$total_files" -eq 0 ]] && return 1

  local safe_chunks=()
  local generated_chunks=()
  local sensitive_files_skipped=0
  local chunk file_name
  for chunk in "${DIFF_CHUNKS[@]}"; do
    if [[ "$FORCE_DIFF" -eq 0 ]] && has_sensitive_patterns "$chunk"; then
      sensitive_files_skipped=$((sensitive_files_skipped + 1))
      continue
    fi

    file_name=$(diff_chunk_file_name "$chunk")
    if is_generated_path "$file_name"; then
      generated_chunks+=("$chunk")
    else
      safe_chunks+=("$chunk")
    fi
  done

  local safe_total=$(( ${#safe_chunks[@]} + ${#generated_chunks[@]} ))
  local generated_files_deprioritized=${#generated_chunks[@]}
  if [[ "${#safe_chunks[@]}" -eq 0 && "${#generated_chunks[@]}" -gt 0 ]]; then
    safe_chunks=("${generated_chunks[@]}")
    generated_files_deprioritized=0
  fi

  local analysis_candidate_total=${#safe_chunks[@]}
  if [[ "$analysis_candidate_total" -eq 0 ]]; then
    if [[ "$sensitive_files_skipped" -gt 0 ]]; then
      step_info "  ⟩ Skipping ${sensitive_files_skipped} sensitive file(s); no safe files remain for per-file analysis."
    fi
    return 1
  fi

  local limit="$FILE_ANALYSIS_LIMIT"
  [[ "$limit" -le 0 ]] && return 1
  [[ "$limit" -gt "$analysis_candidate_total" ]] && limit="$analysis_candidate_total"

  local analysis_indices=()
  mapfile -t analysis_indices < <(build_analysis_indices "$analysis_candidate_total" "$limit")

  dbg "Per-file analysis: total $total_files, safe $safe_total, generated-deprioritized $generated_files_deprioritized, sensitive $sensitive_files_skipped, limit $limit, samples: ${analysis_indices[*]}"

  FILE_ANALYSES=""
  local analysis_total=${#analysis_indices[@]}
  local analysis_start
  analysis_start=$(date +%s)

  BATCH_ANALYSIS_FILE_NAMES=()
  BATCH_ANALYSIS_DIFF_CHUNKS=()

  local selected_index truncated_chunk
  for selected_index in "${analysis_indices[@]}"; do
    chunk="${safe_chunks[$((selected_index - 1))]}"

    file_name=$(diff_chunk_file_name "$chunk")
    truncated_chunk=$(echo "$chunk" | head -c "$MAX_HUNK_CHARS")

    BATCH_ANALYSIS_FILE_NAMES+=("$file_name")
    BATCH_ANALYSIS_DIFF_CHUNKS+=("$truncated_chunk")
  done

  local batch_output_files=()
  local batch_status_files=()
  local batch_pids=()
  local batch_done=()
  local analysis_results=()
  local parallelism="$FILE_ANALYSIS_PARALLELISM"
  [[ "$parallelism" -gt "$analysis_total" ]] && parallelism="$analysis_total"

  if [[ "$sensitive_files_skipped" -gt 0 ]]; then
    step_info "  ⟩ Skipping ${sensitive_files_skipped} sensitive file(s); analyzing ${analysis_total} safe file(s)."
  fi
  if [[ "$generated_files_deprioritized" -gt 0 ]]; then
    step_info "  ⟩ Deprioritizing ${generated_files_deprioritized} generated file(s) for semantic analysis."
  fi
  local status_msg
  status_msg=$(progress_status_text 0 "$analysis_total" "Analyzing files with AI")
  live_status_start "$status_msg" "Sending ${analysis_total} file(s) to AI (blocking, parallelism ${parallelism})..."

  local running=0
  local next_job=0
  local completed=0
  local failed_batches=0
  local i batch_output batch_status analysis status made_progress job_index

  while [[ "$completed" -lt "$analysis_total" ]]; do
    while [[ "$next_job" -lt "$analysis_total" && "$running" -lt "$parallelism" ]]; do
      job_index="$next_job"
      batch_output=$(mktemp)
      batch_status=$(mktemp)
      rm -f "$batch_status"

      batch_output_files[job_index]="$batch_output"
      batch_status_files[job_index]="$batch_status"
      batch_done[job_index]=0

      (
        if run_file_analysis_batch "$((job_index + 1))" "$job_index" 1 "$batch_output"; then
          printf '0\n' > "$batch_status"
        else
          printf '1\n' > "$batch_status"
        fi
      ) &
      batch_pids[job_index]="$!"

      next_job=$((next_job + 1))
      running=$((running + 1))
    done

    made_progress=0
    for ((i=0; i<next_job; i++)); do
      [[ "${batch_done[$i]:-0}" -eq 1 ]] && continue
      [[ -f "${batch_status_files[$i]}" ]] || continue

      status=$(cat "${batch_status_files[$i]}" 2>/dev/null || printf '1')
      wait "${batch_pids[$i]}" 2>/dev/null || true

      batch_done[i]=1
      running=$((running - 1))
      completed=$((completed + 1))
      made_progress=1

      file_name="${BATCH_ANALYSIS_FILE_NAMES[$i]}"
      analysis=$(extract_file_analysis_from_batch "${batch_output_files[$i]}" "$file_name")
      analysis=$(echo "$analysis" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

      if [[ -z "$analysis" ]]; then
        analysis="Changes in $file_name"
      fi

      analysis_results[i]="$analysis"
      [[ "$status" -ne 0 ]] && failed_batches=$((failed_batches + 1))

      status_msg=$(progress_status_text "$completed" "$analysis_total" "Analyzing files with AI" "$(elapsed_since "$analysis_start")")
      live_status_update "$status_msg"
      live_status_print_above "  ${GREEN}→${NC} ${BOLD}${file_name}${NC}: ${DIM}${analysis}${NC}"
    done

    [[ "$completed" -ge "$analysis_total" ]] && break
    status_msg=$(progress_status_text "$completed" "$analysis_total" "Analyzing files with AI" "$(elapsed_since "$analysis_start")")
    live_status_update "$status_msg"
    [[ "$made_progress" -eq 1 ]] || sleep 0.2
  done

  live_status_stop

  FILE_ANALYSES=""
  for ((i=0; i<analysis_total; i++)); do
    file_name="${BATCH_ANALYSIS_FILE_NAMES[$i]}"
    analysis="${analysis_results[$i]:-Changes in $file_name}"
    FILE_ANALYSES+=$'<file name="'${file_name}$'">\n'${analysis}$'\n</file>\n'
  done

  rm -f "${batch_output_files[@]}" "${batch_status_files[@]}"

  local analysis_elapsed
  analysis_elapsed=$(elapsed_since "$analysis_start")
  if [[ "$failed_batches" -gt 0 ]]; then
    if [[ "$sensitive_files_skipped" -gt 0 ]]; then
      step_ok "Analyzed ${analysis_total} of ${safe_total} safe file(s) with ${failed_batches} fallback(s); skipped ${sensitive_files_skipped} sensitive file(s) (${analysis_elapsed})"
    else
      step_ok "Analyzed ${analysis_total} of ${total_files} file(s) with ${failed_batches} fallback(s) (${analysis_elapsed})"
    fi
  else
    if [[ "$sensitive_files_skipped" -gt 0 ]]; then
      step_ok "Analyzed ${analysis_total} of ${safe_total} safe file(s); skipped ${sensitive_files_skipped} sensitive file(s) (${analysis_elapsed})"
    else
      step_ok "Analyzed ${analysis_total} of ${total_files} file(s) (${analysis_elapsed})"
    fi
  fi
}

# ===== Prompt Builder =====
build_commit_type_guidance() {
  cat <<'EOF'
- build: Change the build system, build scripts, compilers, bundlers, packaging, or other build tooling.
- chore: Perform routine maintenance that does not fit another type and does not change product behavior.
- ci: Change CI/CD workflows, pipeline configuration, or automation scripts used by CI/CD.
- deps: Add, remove, or update dependencies or their lockfiles when dependency maintenance is the primary change.
- docs: Change documentation only.
- feat: Add a new user-facing, API, or domain capability.
- fix: Correct a bug or unintended behavior.
- perf: Improve performance without changing the intended behavior.
- refactor: Restructure production code without adding a feature or fixing a bug.
- revert: Undo a previous commit or change.
- style: Change code formatting, whitespace, or other non-behavioral style details only.
- test: Add, correct, or improve tests without changing production behavior.
EOF
}

build_system_prompt_text() {
  local body_rule type_guidance
  if [[ "${STAGED_FILE_COUNT:-0}" -le 1 ]]; then
    body_rule='The staged change has one file: output only the subject line and no body.'
  else
    body_rule="The staged change has multiple files: add a blank line followed by 1-${MAX_BODY_BULLETS} bullet lines. Each bullet must start with \"- \", describe an important diff-backed change, use imperative English, and end with a period."
  fi
  type_guidance=$(build_commit_type_guidance)

  cat <<EOF
You are a senior software engineer.

Your task: write an English Conventional Commit message without a scope.

Rules:
1) The first line must be exactly: <type>: <summary>.
2) Use exactly one type from: build, chore, ci, deps, docs, feat, fix, perf, refactor, revert, style, test.
Choose the type using these definitions:
${type_guidance}
When a dependency, test, documentation, generated artifact, or configuration change only supports a more important feature or fix, use feat or fix for the primary change instead.
3) Do not add a scope such as feat(auth):, Markdown, JSON, a code block, footer, or extra prose.
4) The summary must be concise, specific, and must not end with a period.
5) ${body_rule}
6) Choose the subject from the primary functional capability, user flow, domain model, API behavior, data integrity, or security change. Treat tests and documentation as supporting evidence.
7) Generated clients, schemas, types, snapshots, and codegen output are supporting artifacts. Do not lead the subject with them when source changes exist; mention them only with the feature they support.
8) Treat config, file moves, and deletions as the primary theme only when they are the central behavior change, not merely implementation details of a feature.
9) Avoid generic phrases such as "project structure", "general changes", "features", "components", or "configuration" when concrete diff terminology is available.
Always use English.
EOF
}

build_system_prompt_json() {
  local body_rule type_guidance
  if [[ "${STAGED_FILE_COUNT:-0}" -le 1 ]]; then
    body_rule='bullets (required): an empty array because exactly one file is staged.'
  else
    body_rule="bullets (required): an array containing 1-${MAX_BODY_BULLETS} important diff-backed changes. Each item uses imperative English and ends with a period; do not include the \"- \" marker."
  fi
  type_guidance=$(build_commit_type_guidance)

  cat <<EOF
You are a senior software engineer.

Fill the following field based on the supplied changes:
- type (required): one of build, chore, ci, deps, docs, feat, fix, perf, refactor, revert, style, test. Choose it using these definitions:
${type_guidance}
- summary (required): one concise, specific English sentence fragment without a type prefix, scope, or trailing period.
- ${body_rule}

Do not add a scope, Markdown, a footer, or information absent from the supplied changes.
When a dependency, test, documentation, generated artifact, or configuration change only supports a more important feature or fix, use feat or fix for the primary change instead.
Prioritize the primary functional capability, user flow, domain model, API behavior, data integrity, or security change. Treat tests, documentation, and generated artifacts as supporting evidence. Do not lead the subject with generated clients, schemas, types, snapshots, or codegen output when source changes exist. Avoid generic terms; use concrete terminology from paths, modules, services, environment variables, schemas, APIs, or files when relevant.
Always use English.
EOF
}

build_user_prompt() {
  local safe_mode="$1"

  local prompt
  prompt="Analyze the following changes and write the most suitable commit message. Always use English.

[PRIORITY CHANGES FROM GIT]
${GIT_PRIORITY_CHANGES}

[UNIVERSAL THEME PRIORITIES]
${CHANGE_PRIORITY_HINT}

[SEMANTIC CHANGE SUMMARY]
${SEMANTIC_CHANGE_SUMMARY}

[NAME-STATUS]
${NAME_STATUS}

[GIT SUMMARY]
${GIT_SUMMARY}

[STAT]
${STAT}

[CONCRETE TERMS FROM DIFF]
${DIFF_TERMS}

[COMMIT MESSAGE RULES]
- Prioritize explicit changes from [PRIORITY CHANGES FROM GIT].
- Use [UNIVERSAL THEME PRIORITIES] to choose the commit theme.
- Use [SEMANTIC CHANGE SUMMARY] to distinguish primary functional work from supporting artifacts.
- Do not replace delete/rename/config/API/schema/code with generic terms.
- Do not mention a specific domain such as GPU, database, API, schema, or service unless it appears in the diff or path.
- Avoid \"project structure\", \"general update\", \"various changes\", \"features\", \"components\", or \"configuration\" when concrete terminology is available.
- Use the word \"and\", not the \"&\" symbol.
- Infer one Conventional Commit type without a scope.
- The subject must use the format <type>: <summary> and must not end with a period.
- For one staged file, return no body. For multiple staged files, return 1-${MAX_BODY_BULLETS} important, diff-backed bullets in imperative English; each bullet ends with a period.
- Group related files into one capability-level bullet instead of listing implementation artifacts individually.
- Generated clients, schemas, types, snapshots, and codegen output are supporting artifacts. Do not make them the subject or a standalone bullet when source changes exist; combine them with the API or frontend integration they support.
- When there are many changes, summarize the most important functional themes and do not exceed ${MAX_BODY_BULLETS} bullets.
- Theme priority: domain capability and user flow > API/data integrity/security > frontend integration > runtime behavior > structural cleanup > tests/documentation > generated artifacts."

  if [[ -n "${FILE_ANALYSES:-}" ]]; then
    prompt+=$'\n\n[PER-FILE ANALYSIS]\n'"$FILE_ANALYSES"
  elif [[ "$safe_mode" -eq 0 ]]; then
    prompt+=$'\n\n[DIFF DETAIL]\n'"$TOP_HUNKS"
  else
    prompt+=$'\n\nNote: Safe mode is active, so detailed diffs are not sent.'
  fi

  prompt+=$'\n\nReturn output that follows the rules.'
  echo "$prompt"
}

subject_matches_change_focus() {
  local subject="$1"
  local lower term term_lower
  lower=$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]')

  while IFS= read -r term; do
    [[ -n "$term" ]] || continue
    term_lower=$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')
    [[ "${#term_lower}" -ge 3 ]] || continue
    grep -Fq -- "$term_lower" <<<"$lower" && return 0
  done <<<"${CHANGE_FOCUS_TERMS:-}"

  return 1
}

subject_mentions_structural_change() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  grep -Eiq 'delete|remove|rename|move|migrate|clean|replace|archive' <<<"$lower"
}

subject_mentions_config_change() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  grep -Eiq 'configuration|config|setting|service|runtime|env|variable|parallel|timeout|limit|option|server|deploy|deployment' <<<"$lower"
}

subject_mentions_schema_api_db_change() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  grep -Eiq 'api|schema|database|db|migration|query|endpoint|route|proto|graphql|sql|data model' <<<"$lower"
}

subject_mentions_doc_change() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  grep -Eiq 'document|documentation|guide|readme|runbook|protocol|instruction|note|docs' <<<"$lower"
}

commit_message_quality_issue() {
  local message="$1"
  local subject summary lower evidence_blob
  subject=${message%%$'\n'*}
  summary=${subject#*: }
  lower=$(printf '%s' "$message" | tr '[:upper:]' '[:lower:]')
  evidence_blob="${GIT_PRIORITY_CHANGES}${DIFF_TERMS}${TOP_HUNKS}${FILE_ANALYSES}${CHANGE_PRIORITY_HINT}"

  if ! grep -Eiq '^(build|chore|ci|deps|docs|feat|fix|perf|refactor|revert|style|test): [^[:space:]].*$' <<<"$subject"; then
    printf 'Subject must use an allowed Conventional Commit type followed by a colon and summary, without a scope.'
    return 0
  fi

  if grep -Eq '&' <<<"$message"; then
    printf 'Commit message uses an untidy style; use the word "and" instead of the "&" symbol.'
    return 0
  fi

  if grep -Eq 'project[[:space:]-]*structure|general update|general changes|various changes|several changes' <<<"$lower"; then
    printf 'Commit message is too generic; use a concrete Git theme such as delete/rename, config/runtime, API/schema/database, code, or documentation.'
    return 0
  fi

  if [[ "${HAS_FUNCTIONAL_CHANGE:-0}" -eq 1 ]] && grep -Eiq 'generated (types?|client|schema)|type generation|code generation|generated api' <<<"$summary"; then
    printf 'Subject leads with generated output even though functional source changes exist; lead with the domain capability, API behavior, security, or frontend user flow instead.'
    return 0
  fi

  if [[ "${HAS_FUNCTIONAL_CHANGE:-0}" -eq 1 ]] && grep -Eiq '^(add|create|implement|update) (features|components|configuration|settings)$|^(add|create|implement|update) (project|application|app|system|service) (features|components|configuration|settings)$' <<<"$summary"; then
    printf 'Subject is too generic for a functional change; name the concrete domain capability, API behavior, security control, or frontend flow.'
    return 0
  fi

  if grep -Eq 'gpu|cuda|nvidia|rocm' <<<"$lower" && ! grep -Eiq 'gpu|cuda|nvidia|rocm' <<<"$evidence_blob"; then
    printf 'Commit message mentions GPU or hardware, but that signal is absent from the diff or path; use concrete Git terminology.'
    return 0
  fi

  if [[ "${HAS_API_CHANGE:-0}" -eq 1 || "${HAS_DATABASE_CHANGE:-0}" -eq 1 ]]; then
    if subject_mentions_schema_api_db_change "$summary" || subject_matches_change_focus "$summary"; then
      return 1
    fi
    printf 'Subject does not cover the API, data model, or database theme that is central to the changed source files.'
    return 0
  fi

  if [[ ( "${HAS_DELETE:-0}" -eq 1 || "${HAS_RENAME:-0}" -eq 1 ) && "${HAS_FUNCTIONAL_CHANGE:-0}" -eq 0 ]]; then
    if subject_mentions_structural_change "$summary" || subject_matches_change_focus "$summary"; then
      return 1
    fi
    printf 'Subject does not cover the structural cleanup or relocation that is the primary changed theme.'
    return 0
  fi

  if [[ "${HAS_CONFIG_CHANGE:-0}" -eq 1 && "${HAS_API_CHANGE:-0}" -eq 0 && "${HAS_DATABASE_CHANGE:-0}" -eq 0 && "${HAS_FRONTEND_CHANGE:-0}" -eq 0 ]]; then
    if subject_mentions_config_change "$summary" || subject_matches_change_focus "$summary"; then
      return 1
    fi
    printf 'Subject does not cover the runtime or service behavior that is central to the changed files.'
    return 0
  fi

  if [[ "${HAS_DOC_CHANGE:-0}" -eq 1 && "${HAS_CODE_CHANGE:-0}" -eq 0 ]]; then
    if subject_mentions_doc_change "$summary" || subject_matches_change_focus "$summary"; then
      return 1
    fi
    printf 'Subject does not cover documentation or guidance, even though the changes are documentation-only.'
    return 0
  fi

  return 1
}

build_quality_retry_prompt() {
  local base_prompt="$1"
  local previous_message="$2"
  local issue="$3"

  cat <<EOF
${base_prompt}

[PREVIOUS COMMIT MESSAGE CORRECTION]
Previous commit message:
${previous_message}

Issue:
${issue}

Rewrite the complete commit message to be more accurate, concrete, and concise.
Follow the semantic priority: domain capability and user flow > API/data integrity/security > frontend integration > runtime behavior > structural cleanup > tests/documentation > generated artifacts.
Return only the required format: <type>: <summary>, optionally followed by a blank line and the required bullet body. Do not use a scope, Markdown, extra JSON, or a footer.
EOF
}

ollama_request() {
  local payload="$1"

  local tmp_body tmp_err http_code body err_txt curl_status start_ms end_ms elapsed_ms
  tmp_body=$(mktemp)
  tmp_err=$(mktemp)

  local max_time="${2:-120}"
  dbg "Command: curl -sS --connect-timeout 5 --max-time ${max_time} -o '<temp>' -w '%{http_code}' -H 'Content-Type: application/json' -d '<payload>' ${OLLAMA_API_URL}"
  start_ms=$(date +%s%3N)
  if http_code=$(curl -sS --connect-timeout 5 --max-time "$max_time" \
    -o "$tmp_body" -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$OLLAMA_API_URL" 2>"$tmp_err"); then
    curl_status=0
  else
    curl_status=$?
  fi
  end_ms=$(date +%s%3N)
  elapsed_ms=$((end_ms - start_ms))

  body=$(cat "$tmp_body" || true)
  err_txt=$(cat "$tmp_err" || true)
  rm -f "$tmp_body" "$tmp_err"

  dbg "curl exit status: ${curl_status}; HTTP status: ${http_code:-<empty>}; duration: ${elapsed_ms}ms; response bytes: ${#body}"
  dbg_block "Ollama HTTP response body" "$body"
  [[ -z "$err_txt" ]] || dbg_block "Ollama HTTP stderr" "$err_txt"

  if [[ "$curl_status" -ne 0 ]]; then
    dbg "curl request failed: ${err_txt:-<none>}"
    return 1
  fi

  if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
    dbg "Invalid HTTP status returned by curl: ${http_code:-<empty>}"
    return 1
  fi

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    if echo "$body" | jq -e . >/dev/null 2>&1; then
      local api_err
      api_err=$(echo "$body" | jq -r '.error // empty' 2>/dev/null || true)
      [[ -n "$api_err" ]] && err "Ollama error ($http_code): $api_err"
    else
      err "Ollama HTTP error ($http_code)."
    fi
    [[ -n "$err_txt" ]] && err "$err_txt"
    return 1
  fi

  echo "$body"
}

cap_num_predict() {
  local num_predict="$1"

  [[ -z "$num_predict" ]] && { printf '%s' "$num_predict"; return 0; }
  if [[ "$num_predict" =~ ^[0-9]+$ && "$AI_MAX_NUM_PREDICT" =~ ^[0-9]+$ && "$num_predict" -gt "$AI_MAX_NUM_PREDICT" ]]; then
    dbg "num_predict ${num_predict} exceeds ${AI_MAX_NUM_PREDICT}; using the maximum."
    num_predict="$AI_MAX_NUM_PREDICT"
  fi

  printf '%s' "$num_predict"
}

ollama_chat() {
  local system_prompt="$1"
  local user_prompt="$2"
  local format_json_schema="${3:-}"   # empty = non-structured
  local max_time="${4:-120}"          # timeout curl (default 120s)
  # The fifth argument from earlier versions is still accepted but ignored.
  local num_predict_override="${6:-}" # empty = use AI_NUM_PREDICT

  local options num_predict
  num_predict="$AI_NUM_PREDICT"
  [[ -n "$num_predict_override" ]] && num_predict="$num_predict_override"
  num_predict=$(cap_num_predict "$num_predict")

  options=$(jq -n --argjson temperature "$AI_TEMPERATURE" '{temperature:$temperature}')
  if [[ -n "$num_predict" ]]; then
    options=$(jq -c --argjson n "$num_predict" '. + {num_predict:$n}' <<<"$options")
  fi

  local payload
  if [[ -n "$format_json_schema" ]]; then
    payload=$(jq -n \
      --arg model "$OLLAMA_MODEL" \
      --arg sp "$system_prompt" \
      --arg up "$user_prompt" \
      --argjson opts "$options" \
      --argjson fmt "$format_json_schema" \
      '{
        model: $model,
        stream: false,
        options: $opts,
        format: $fmt,
        messages: [
          {role:"system", content:$sp},
          {role:"user", content:$up}
        ]
      }')
  else
    payload=$(jq -n \
      --arg model "$OLLAMA_MODEL" \
      --arg sp "$system_prompt" \
      --arg up "$user_prompt" \
      --argjson opts "$options" \
      '{
        model: $model,
        stream: false,
        options: $opts,
        messages: [
          {role:"system", content:$sp},
          {role:"user", content:$up}
        ]
      }')
  fi

  # Send the think control to Ollama, defaulting to no thinking.
  payload=$(jq -c \
    --arg think "$AI_THINK" \
    '. + {think: (if $think == "true" then true elif $think == "false" then false else $think end)}' \
    <<<"$payload")

  local request_mode="plain-text"
  [[ -n "$format_json_schema" ]] && request_mode="structured"
  dbg "Ollama request mode: ${request_mode}; timeout: ${max_time}s"
  dbg "Ollama model: ${OLLAMA_MODEL}"
  dbg "Ollama options: $(jq -c '.options' <<<"$payload" 2>/dev/null || printf '{}')"
  dbg "Payload size: ${#payload} chars"
  dbg_block "Ollama system prompt" "$system_prompt"
  dbg_block "Ollama user prompt" "$user_prompt"
  if [[ -n "$format_json_schema" ]]; then
    dbg_block "Ollama JSON Schema" "$format_json_schema"
  fi
  dbg_block "Ollama request payload" "$payload"

  _ollama_chat_blocking "$payload" "$max_time"
}

_ollama_chat_blocking() {
  local payload="$1"
  local max_time="$2"

  # Ensure Ollama returns one complete response.
  local blocking_payload
  blocking_payload=$(jq -c '.stream = false' <<<"$payload")

  local resp text
  if ! resp=$(ollama_request "$blocking_payload" "$max_time"); then
    validation_fail "ollama.request_failed" "The HTTP request did not return a successful response."
    return 1
  fi

  if ! echo "$resp" | jq -e . >/dev/null 2>&1; then
    validation_fail "ollama.invalid_json" "The Ollama API response body is not valid JSON."
    return 1
  fi
  local prompt_tokens eval_tokens response_done done_reason total_duration load_duration
  prompt_tokens=$(echo "$resp" | jq -r '.prompt_eval_count // 0' 2>/dev/null || echo 0)
  eval_tokens=$(echo "$resp" | jq -r '.eval_count // 0' 2>/dev/null || echo 0)
  response_done=$(echo "$resp" | jq -r '.done // false' 2>/dev/null || echo false)
  done_reason=$(echo "$resp" | jq -r '.done_reason // "<empty>"' 2>/dev/null || echo "<empty>")
  total_duration=$(echo "$resp" | jq -r '.total_duration // 0' 2>/dev/null || echo 0)
  load_duration=$(echo "$resp" | jq -r '.load_duration // 0' 2>/dev/null || echo 0)
  if [[ -f "${TOKEN_LOG_FILE:-}" ]]; then
    echo "$((prompt_tokens + eval_tokens))" >> "$TOKEN_LOG_FILE"
  fi
  dbg "Ollama result: done=${response_done}; done_reason=${done_reason}; total_duration_ns=${total_duration}; load_duration_ns=${load_duration}"
  dbg "Ollama usage: prompt_eval_count=${prompt_tokens}, eval_count=${eval_tokens}"
  text=$(echo "$resp" | jq -r '.message.content // empty' 2>/dev/null || true)
  dbg_block "Ollama assistant content" "$text"
  if [[ -z "$text" ]]; then
    validation_fail "ollama.empty_content" "The assistant response contains no message.content."
    return 1
  fi
  printf '%s' "$text"
}

is_allowed_commit_type() {
  case "$1" in
    build|chore|ci|deps|docs|feat|fix|perf|refactor|revert|style|test) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_commit_type() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

normalize_commit_summary() {
  local summary="$1"

  summary=$(printf '%s' "$summary" | sed -E 's/[[:space:]]*&[[:space:]]*/ and /g')
  summary=$(printf '%s' "$summary" | sed -E 's/[Pp]arallelisme/parallelism/g; s/[Pp]aralellism/parallelism/g; s/[Pp]arallel([[:space:]]|$)/parallel\1/g')
  summary=$(printf '%s' "$summary" | tr -s ' ')
  summary=$(printf '%s' "$summary" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\.$//')

  printf '%s' "$summary"
}

normalize_commit_bullet() {
  local bullet="$1"

  bullet=$(printf '%s' "$bullet" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
  bullet=$(printf '%s' "$bullet" | sed -E 's/[[:space:]]*&[[:space:]]*/ and /g')
  bullet=$(printf '%s' "$bullet" | tr -s ' ')
  bullet=$(printf '%s' "$bullet" | sed -E 's/[!?:;]+$//')
  [[ -z "$bullet" || "$bullet" == *. ]] || bullet+="."

  printf '%s' "$bullet"
}

validate_commit_summary() {
  local summary="$1"

  if [[ -z "$summary" ]]; then
    validation_fail "summary.empty" "The summary is empty."
    return 1
  fi
  if [[ "${#summary}" -lt 8 ]]; then
    validation_fail "summary.too_short" "The summary has ${#summary} characters; minimum is 8."
    return 1
  fi
  if [[ "$summary" == *$'\n'* || "$summary" == *$'\r'* ]]; then
    validation_fail "summary.multiline" "The summary contains a line break."
    return 1
  fi
  if [[ "$summary" == *'`'* || "$summary" == *'*'* || "$summary" == '#'* || "$summary" == '>'* ]]; then
    validation_fail "summary.markdown" "The summary contains Markdown syntax."
    return 1
  fi
  if [[ "$summary" == *'.' ]]; then
    validation_fail "summary.trailing_period" "The summary ends with a period."
    return 1
  fi
  if grep -Eiq '^[[:space:]]*(build|chore|ci|deps|docs|feat|fix|perf|refactor|revert|style|test)(\([^)]+\))?[!:：]' <<<"$summary"; then
    validation_fail "summary.duplicate_type" "The summary contains another Conventional Commit prefix."
    return 1
  fi
  if printf '%s' "$summary" | LC_ALL=C grep -qP '[\x00-\x1f\x7f]'; then
    validation_fail "summary.control_character" "The summary contains a control character."
    return 1
  fi
  if ! printf '%s' "$summary" | grep -Eq '^[[:space:]]*[^[:space:]].*$'; then
    validation_fail "summary.whitespace_only" "The summary contains only whitespace."
    return 1
  fi
}

validate_commit_bullet() {
  local bullet="$1"

  if [[ -z "$bullet" ]]; then
    validation_fail "bullet.empty" "A commit-message bullet is empty."
    return 1
  fi
  if [[ "$bullet" == *$'\n'* || "$bullet" == *$'\r'* ]]; then
    validation_fail "bullet.multiline" "A bullet contains a line break."
    return 1
  fi
  if [[ "$bullet" == *'`'* || "$bullet" == *'*'* || "$bullet" == '```'* || "$bullet" == '#'* || "$bullet" == '>'* ]]; then
    validation_fail "bullet.markdown" "A bullet contains unsupported Markdown syntax."
    return 1
  fi
  if [[ "$bullet" != *. ]]; then
    validation_fail "bullet.missing_period" "A bullet does not end with a period."
    return 1
  fi
  if printf '%s' "$bullet" | LC_ALL=C grep -qP '[\x00-\x1f\x7f]'; then
    validation_fail "bullet.control_character" "A bullet contains a control character."
    return 1
  fi
  if ! printf '%s' "$bullet" | grep -Eq '^[[:space:]]*[^[:space:]].*$'; then
    validation_fail "bullet.whitespace_only" "A bullet contains only whitespace."
    return 1
  fi
}

compose_commit_message() {
  local type="$1"
  local summary="$2"
  shift 2
  local bullet

  printf '%s: %s' "$type" "$summary"
  if [[ "$#" -gt 0 ]]; then
    printf '\n\n'
    for bullet in "$@"; do
      printf -- '- %s\n' "$bullet"
    done
  fi
}

validate_commit_message_fields() {
  local type="$1"
  local summary="$2"
  shift 2
  local bullet message normalized_bullet normalized_existing
  local i j
  local -a bullets=("$@")

  if ! is_allowed_commit_type "$type"; then
    validation_fail "type.invalid" "Unsupported Conventional Commit type: ${type:-<empty>}."
    return 1
  fi
  validate_commit_summary "$summary" || return 1

  if [[ "${STAGED_FILE_COUNT:-0}" -le 1 ]]; then
    if [[ "$#" -ne 0 ]]; then
      validation_fail "body.unexpected" "Exactly one file is staged, but the response contains ${#bullets[@]} bullet(s)."
      return 1
    fi
  else
    if [[ "$#" -lt 1 ]]; then
      validation_fail "body.missing" "Multiple files are staged, but the response has no body bullets."
      return 1
    fi
    if [[ "$#" -gt "$MAX_BODY_BULLETS" ]]; then
      validation_fail "body.too_many_bullets" "The response has ${#bullets[@]} bullets; maximum is ${MAX_BODY_BULLETS}."
      return 1
    fi
  fi

  for ((i=0; i<${#bullets[@]}; i++)); do
    bullet="${bullets[i]}"
    if ! validate_commit_bullet "$bullet"; then
      dbg "Invalid bullet index: $((i + 1))"
      return 1
    fi
    normalized_bullet=$(printf '%s' "$bullet" | tr '[:upper:]' '[:lower:]')
    for ((j=0; j<i; j++)); do
      normalized_existing=$(printf '%s' "${bullets[j]}" | tr '[:upper:]' '[:lower:]')
      if [[ "$normalized_bullet" == "$normalized_existing" ]]; then
        validation_fail "body.duplicate_bullet" "Bullets $((j + 1)) and $((i + 1)) are duplicates."
        return 1
      fi
    done
  done

  message=$(compose_commit_message "$type" "$summary" "$@")
  if [[ "${#message}" -gt "$MAX_COMMIT_MESSAGE_LENGTH" ]]; then
    validation_fail "message.too_long" "The message has ${#message} characters; maximum is ${MAX_COMMIT_MESSAGE_LENGTH}."
    return 1
  fi
}

clean_plain_commit_message() {
  local message="$1"
  local line line_number=0 type summary bullet
  local -a bullets=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line_number" -eq 0 ]]; then
      if [[ "$line" =~ ^(build|chore|ci|deps|docs|feat|fix|perf|refactor|revert|style|test):[[:space:]]+(.+)$ ]]; then
        type=$(normalize_commit_type "${BASH_REMATCH[1]}")
        summary=$(normalize_commit_summary "${BASH_REMATCH[2]}")
      else
        validation_fail "plain.invalid_subject" "Line 1 must match <type>: <summary> without a scope."
        return 1
      fi
    elif [[ -z "${line//[[:space:]]/}" ]]; then
      :
    elif [[ "$line" =~ ^-[[:space:]]+(.+)$ ]]; then
      bullet=$(normalize_commit_bullet "${BASH_REMATCH[1]}")
      bullets+=("$bullet")
    elif [[ "${STAGED_FILE_COUNT:-0}" -gt 1 && "$line" =~ ^(build|chore|ci|deps|docs|feat|fix|perf|refactor|revert|style|test):[[:space:]]+(.+)$ ]]; then
      # Some small models return multiple Conventional Commit candidates.
      # Keep the first subject and convert later candidates into body bullets.
      bullet=$(normalize_commit_bullet "${BASH_REMATCH[2]}")
      bullets+=("$bullet")
    else
      validation_fail "plain.unexpected_line" "Line $((line_number + 1)) is neither blank nor a '- ' bullet."
      return 1
    fi
    line_number=$((line_number + 1))
  done <<< "$message"

  if [[ "$line_number" -le 0 ]]; then
    validation_fail "plain.empty" "The plain-text response is empty."
    return 1
  fi
  validate_commit_message_fields "$type" "$summary" "${bullets[@]}" || return 1
  compose_commit_message "$type" "$summary" "${bullets[@]}"
}

append_fallback_topic() {
  local topic="$1"
  local existing

  for existing in "${FALLBACK_TOPICS[@]}"; do
    [[ "$existing" == "$topic" ]] && return 0
  done

  FALLBACK_TOPICS+=("$topic")
}

build_fallback_summary() {
  FALLBACK_TOPICS=()

  [[ "${HAS_DELETE:-0}" -eq 1 ]] && append_fallback_topic "remove ${DELETE_FOCUS_LABEL:-file}"
  [[ "${HAS_RENAME:-0}" -eq 1 ]] && append_fallback_topic "move ${RENAME_FOCUS_LABEL:-file}"
  [[ "${HAS_CONFIG_CHANGE:-0}" -eq 1 ]] && append_fallback_topic "update configuration"
  [[ "${HAS_SCHEMA_API_DB_CHANGE:-0}" -eq 1 ]] && append_fallback_topic "update API/schema"
  [[ "${HAS_CODE_CHANGE:-0}" -eq 1 ]] && append_fallback_topic "update code logic"
  [[ "${HAS_DOC_CHANGE:-0}" -eq 1 ]] && append_fallback_topic "update documentation"

  local summary
  case "${#FALLBACK_TOPICS[@]}" in
    0)
      summary="update ${FILES_CHANGED:-staged files}"
      ;;
    1)
      summary="${FALLBACK_TOPICS[0]}"
      ;;
    2)
      summary="${FALLBACK_TOPICS[0]} and ${FALLBACK_TOPICS[1]}"
      ;;
    *)
      summary="${FALLBACK_TOPICS[0]}, ${FALLBACK_TOPICS[1]}, and ${FALLBACK_TOPICS[2]}"
      ;;
  esac

  summary=$(normalize_commit_summary "$summary")

  printf '%s' "$summary"
}

build_fallback_type() {
  if [[ "${HAS_DOC_CHANGE:-0}" -eq 1 && "${HAS_CODE_CHANGE:-0}" -eq 0 && "${HAS_CONFIG_CHANGE:-0}" -eq 0 && "${HAS_SCHEMA_API_DB_CHANGE:-0}" -eq 0 ]]; then
    printf 'docs'
  elif [[ "${HAS_DELETE:-0}" -eq 1 || "${HAS_RENAME:-0}" -eq 1 ]]; then
    printf 'refactor'
  else
    printf 'chore'
  fi
}

build_fallback_bullets() {
  [[ "${STAGED_FILE_COUNT:-0}" -gt 1 ]] || return 0

  local status path1 path2 action count=0
  while IFS=$'\t' read -r status path1 path2; do
    [[ -n "${status:-}" && -n "${path1:-}" ]] || continue
    case "$status" in
      A)  action="Add ${path1}." ;;
      D)  action="Remove ${path1}." ;;
      R*) action="Rename ${path1} to ${path2:-$path1}." ;;
      *)  action="Update ${path1}." ;;
    esac
    printf '%s\n' "$action"
    count=$((count + 1))
    [[ "$count" -ge "$MAX_BODY_BULLETS" ]] && break
  done < <(git diff --cached --name-status -M | head -n "$MAX_BODY_BULLETS" || true)
}

build_fallback_commit_message() {
  local type summary message
  local -a bullets=()

  type=$(build_fallback_type)
  summary=$(build_fallback_summary)
  if [[ "${STAGED_FILE_COUNT:-0}" -gt 1 ]]; then
    mapfile -t bullets < <(build_fallback_bullets)
    [[ "${#bullets[@]}" -gt 0 ]] || bullets=("Update staged files.")
  fi

  message=$(compose_commit_message "$type" "$summary" "${bullets[@]}")
  while [[ "${#message}" -gt "$MAX_COMMIT_MESSAGE_LENGTH" && "${#bullets[@]}" -gt 1 ]]; do
    unset 'bullets[-1]'
    message=$(compose_commit_message "$type" "$summary" "${bullets[@]}")
  done

  if [[ "${#message}" -gt "$MAX_COMMIT_MESSAGE_LENGTH" ]]; then
    type='ci'
    summary='update it'
    if [[ "${STAGED_FILE_COUNT:-0}" -gt 1 ]]; then
      bullets=("Update.")
    else
      bullets=()
    fi
    message=$(compose_commit_message "$type" "$summary" "${bullets[@]}")
  fi

  printf '%s' "$message"
}

build_commit_schema() {
  local min_bullets=0
  [[ "${STAGED_FILE_COUNT:-0}" -gt 1 ]] && min_bullets=1

  jq -n --argjson min_bullets "$min_bullets" --argjson max_bullets "$MAX_BODY_BULLETS" '
    {
      type: "object",
      additionalProperties: false,
      properties: {
        type: {type:"string", enum:["build", "chore", "ci", "deps", "docs", "feat", "fix", "perf", "refactor", "revert", "style", "test"]},
        summary: {type:"string"},
        bullets: {
          type:"array",
          minItems:$min_bullets,
          maxItems:$max_bullets,
          items:{type:"string"}
        }
      },
      required: ["type", "summary", "bullets"]
    }
    '
}

compose_commit_from_json() {
  local json="$1"
  local type summary bullet
  local -a bullets=()

  if ! echo "$json" | jq -e '(.type | type == "string") and (.summary | type == "string") and (.bullets | type == "array")' >/dev/null; then
    validation_fail "structured.invalid_fields" "Expected string fields type and summary plus an array field bullets."
    return 1
  fi
  type=$(echo "$json" | jq -r '.type // empty')
  summary=$(echo "$json" | jq -r '.summary // empty')
  type=$(normalize_commit_type "$type")
  summary=$(normalize_commit_summary "$summary")
  while IFS= read -r bullet; do
    bullets+=("$(normalize_commit_bullet "$bullet")")
  done < <(echo "$json" | jq -r '.bullets // [] | .[]')

  validate_commit_message_fields "$type" "$summary" "${bullets[@]}" || return 1
  compose_commit_message "$type" "$summary" "${bullets[@]}"
}

generate_commit_message() {
  # Step headers are called from main() to avoid a subshell counter issue.

  local safe_mode=0
  if [[ "$FORCE_DIFF" -eq 0 ]] && detect_sensitive_patterns; then
    safe_mode=1
    warn "Sensitive patterns detected. Safe mode enabled (detailed diffs are not sent)."
  fi

  collect_context "$safe_mode"
  dbg "Generation safe mode: ${safe_mode}"
  debug_git_context "$safe_mode"
  step_ok "Context: ${STAGED_FILE_COUNT} file(s) staged"

  FILE_ANALYSES=""
  if [[ "$DO_FILE_ANALYSIS" -eq 1 ]]; then
    analyze_files_individually || true
  fi

  local attempts=10
  local system_prompt base_user_prompt user_prompt schema content json commit_msg quality_issue
  local structured_available="$USE_STRUCTURED_OUTPUT"
  base_user_prompt=$(build_user_prompt "$safe_mode")
  user_prompt="$base_user_prompt"

  local retry_delay=1
  local retry_delay_max=10
  for ((i=1; i<=attempts; i++)); do
    dbg "Attempt $i/$attempts"
    [[ "$i" -gt 1 ]] && {
      step_info "Retry $i/$attempts..."
      dbg "Retry delay: ${retry_delay}s"
      sleep "$retry_delay"
      retry_delay=$((retry_delay + 1))
      [[ "$retry_delay" -le "$retry_delay_max" ]] || retry_delay="$retry_delay_max"
    }

    if [[ "$structured_available" -eq 1 ]]; then
      system_prompt=$(build_system_prompt_json)
      schema=$(build_commit_schema)
      blocking_status_start "Sending prompt to AI model (structured)..."

      if ! content=$(ollama_chat "$system_prompt" "$user_prompt" "$schema"); then
        blocking_status_stop
        dbg "Structured output failed (request/parse). Falling back to plain text."
      else
        blocking_status_stop

        # Ollama returns JSON as a string in message.content.
        if json=$(printf '%s' "$content" | jq -e . 2>/dev/null); then
          if commit_msg=$(compose_commit_from_json "$json"); then
            if quality_issue=$(commit_message_quality_issue "$commit_msg"); then
              dbg "Commit message needs retry: $quality_issue"
              user_prompt=$(build_quality_retry_prompt "$base_user_prompt" "$commit_msg" "$quality_issue")
              commit_msg=""
              continue
            fi
            break
          fi
          dbg "JSON is valid but commit-message composition/validation failed."
        else
          dbg "Structured output is not valid JSON."
          if commit_msg=$(clean_plain_commit_message "$content"); then
            if quality_issue=$(commit_message_quality_issue "$commit_msg"); then
              dbg "Commit message needs retry: $quality_issue"
              user_prompt=$(build_quality_retry_prompt "$base_user_prompt" "$commit_msg" "$quality_issue")
              commit_msg=""
              continue
            fi
            dbg "Structured response contained a valid plain-text commit message."
            break
          fi
        fi
      fi

      structured_available=0
      dbg "Falling back to plain text within the current attempt."
    fi

    system_prompt=$(build_system_prompt_text)
    blocking_status_start "Sending prompt to AI model (plain text)..."
    if ! content=$(ollama_chat "$system_prompt" "$user_prompt" ""); then
      blocking_status_stop
      continue
    fi
    blocking_status_stop

    if commit_msg=$(clean_plain_commit_message "$content"); then
      if quality_issue=$(commit_message_quality_issue "$commit_msg"); then
        dbg "Commit message needs retry: $quality_issue"
        user_prompt=$(build_quality_retry_prompt "$base_user_prompt" "$commit_msg" "$quality_issue")
        commit_msg=""
        continue
      fi
      break
    fi

    user_prompt="${base_user_prompt}"$'\n\n[RETRY]\nYour previous output was invalid. Return only a plain-text Conventional Commit message without a scope or Markdown. Use <type>: <summary>; include the required bullet body only when multiple files are staged.'
  done

  if [[ -z "${commit_msg:-}" ]]; then
    warn "Failed to generate a valid commit message from AI. Using fallback."
    commit_msg=$(build_fallback_commit_message)
  fi

  printf '%s' "$commit_msg"
}

do_commit() {
  local msg="$1"
  show_step "Commit"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "DRY RUN: no commit, push, or Git state changes."
    return 0
  fi

  # Interactive mode: show the message and ask for confirmation.
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    info "===== Commit Message ====="
    echo "$msg" >&2
    info "=========================="
    local confirm
    read -rp "Continue with commit? [Y/n/e(dit)] " confirm
    case "${confirm,,}" in
      n|no)  warn "Commit cancelled."; exit 0 ;;
      e|edit)
        local tmpfile_edit
        tmpfile_edit=$(mktemp --suffix=.gitcommit)
        printf '%s\n' "$msg" > "$tmpfile_edit"
        ${EDITOR:-vi} "$tmpfile_edit"
        msg=$(cat "$tmpfile_edit")
        rm -f "$tmpfile_edit"
        [[ -z "$(echo "$msg" | sed '/^[[:space:]]*$/d')" ]] && { warn "Commit message is empty. Cancelled."; exit 0; }
        ;;
      *)  ;; # default: continue
    esac
  fi

  local tmpfile
  tmpfile=$(mktemp)
  printf '%s\n' "$msg" > "$tmpfile"

  if [[ "$NO_VERIFY" -eq 1 ]]; then
    dbg "Command: git commit --no-verify -F <commit-message-file>"
    git commit --no-verify -F "$tmpfile"
  else
    dbg "Command: git commit -F <commit-message-file>"
    git commit -F "$tmpfile"
  fi

  rm -f "$tmpfile"

  local short_hash
  short_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "???")
  step_ok "Committed: ${short_hash}"
}

do_push() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ "$DO_PUSH" -eq 0 ]] && { step_info "Push skipped (--no-push)"; return 0; }

  show_step "Push"

  local branch remote
  branch=$(git branch --show-current 2>/dev/null || echo "?")

  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    spinner_start "Pushing to remote..."
    dbg "Command: git push"
    git push
    spinner_stop
    remote=$(git remote | head -n 1 || echo "origin")
    step_ok "Pushed to ${remote}/${branch}"
    return 0
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    remote="origin"
  else
    remote=$(git remote | head -n 1 || true)
  fi

  if [[ -z "$remote" ]]; then
    warn "No remote repository. Skipping push."
    return 0
  fi

  spinner_start "Pushing to ${remote}/${branch}..."
  dbg "Command: git push -u ${remote} ${branch}"
  git push -u "$remote" "$branch"
  spinner_stop
  step_ok "Pushed to ${remote}/${branch}"
}

acquire_lock() {
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  LOCK_FILE="${git_dir}/git-ai.lock"
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    die "git-ai is already running in this repository. Wait for the previous process to finish."
  fi
  dbg "Lock acquired: $LOCK_FILE"
}

release_lock() {
  if [[ -n "${LOCK_FILE:-}" ]]; then
    flock -u 200 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
  fi
}

main() {
  TOKEN_LOG_FILE=$(mktemp)
  export TOKEN_LOG_FILE

  parse_args "$@"
  timer_start

  check_git_repo
  preselect_ollama_model_for_banner
  show_banner

  acquire_lock
  trap 'live_status_stop; spinner_stop; restore_cursor; cleanup_dry_run_index; release_lock; rm -f "${TOKEN_LOG_FILE:-}"' EXIT
  setup_dry_run_index
  debug_runtime_configuration

  # Calculate total steps from the configuration.
  # Base: dependencies (1) + stage (2) + analyze/generate (3) + commit (4) + push (5)
  TOTAL_STEPS=5
  [[ "$DO_PUSH" -eq 0 ]] && TOTAL_STEPS=$((TOTAL_STEPS - 1))

  check_deps
  stage_changes

  show_step "Analyzing changes and creating commit message"

  local commit_msg_file
  commit_msg_file=$(mktemp)

  local gen_start
  gen_start=$(date +%s)

  generate_commit_message > "$commit_msg_file"

  local gen_elapsed
  gen_elapsed=$(elapsed_since "$gen_start")
  step_ok "Commit message received (${gen_elapsed})"

  local commit_msg
  commit_msg=$(cat "$commit_msg_file")
  rm -f "$commit_msg_file"

  do_commit "$commit_msg"
  do_push

  # Final summary
  local summary_detail=""
  if [[ "$DRY_RUN" -eq 0 ]]; then
    local short_hash
    short_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "")
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo "")
    if [[ -n "$short_hash" ]]; then
      summary_detail="Commit: ${short_hash}"
      if [[ "$DO_PUSH" -eq 1 ]]; then
        local remote
        remote=$(git remote | head -n 1 2>/dev/null || true)
        if [[ -n "$remote" ]]; then
          summary_detail+=" → ${remote}/${branch}"
        fi
      fi
    fi
  else
    summary_detail="Mode: dry-run"
  fi
  show_summary "$summary_detail"

  # Calculate total tokens
  local total_tokens=0
  if [[ -f "${TOKEN_LOG_FILE:-}" ]]; then
    while read -r t; do
      total_tokens=$((total_tokens + t))
    done < "$TOKEN_LOG_FILE"
  fi

  local formatted_tokens="$total_tokens"
  if command -v awk >/dev/null 2>&1; then
    formatted_tokens=$(awk -v n="$total_tokens" 'BEGIN {
      s = sprintf("%d", n)
      out = ""
      while (length(s) > 3) {
        out = "." substr(s, length(s) - 2, 3) out
        s = substr(s, 1, length(s) - 3)
      }
      print s out
    }')
  fi

  # Keep the commit result at the bottom.
  echo -e "Commit message \"${commit_msg}\""
  echo -e "${DIM}Token usage ${formatted_tokens}${NC}"
}

main "$@"
