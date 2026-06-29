#!/usr/bin/env bash
#
# git-ai.sh - Git AI Commit Assistant (Ollama)
# ------------------------------------------------------
# Ringkasan:
# - Auto stage (opsional) -> generate commit message via Ollama -> commit -> push (opsional)
# - Format message: 1 baris subject tanpa body/footer
# - Safe mode: sembunyikan diff detail jika terdeteksi pola sensitif
# - Optional analisis per-file (dibatasi) agar prompt lebih ringkas
# - Structured output (Ollama `format`/JSON Schema) untuk hasil lebih stabil
#
# Dependencies: git, curl, jq
#
# Usage cepat:
#   /opt/services/utils/bin/git-ai.sh                 # stage all, generate commit, push
#   /opt/services/utils/bin/git-ai.sh -n              # commit tanpa push
#   /opt/services/utils/bin/git-ai.sh -p              # git add -p
#   /opt/services/utils/bin/git-ai.sh --dry-run       # hanya tampilkan commit message
#
# Config:
#   bin/git-ai.conf                 # konfigurasi default di satu folder dengan script
#

set -euo pipefail

# ===== Version =====
VERSION="1.4.18"

# ===== Konfigurasi =====
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_CONFIG_FILE="${SCRIPT_DIR}/git-ai.conf"

# Load config file di folder script jika ada.
# shellcheck source=/dev/null
[[ -f "$SCRIPT_CONFIG_FILE" ]] && source "$SCRIPT_CONFIG_FILE"

# ===== Perilaku =====
DO_PUSH=1
DO_STAGE=1
USE_PATCH=0
DRY_RUN=0
DEBUG=0
FORCE_DIFF=0
NO_BANNER=0
NO_PULL=0
NO_VERIFY=0
INTERACTIVE=0
DRY_RUN_INDEX_FILE=""
STAGED_FILE_COUNT=0

# Per-file analysis tuning
DO_FILE_ANALYSIS=1

# Structured output (Ollama `format`)
USE_STRUCTURED_OUTPUT=1

# Fallback minimal jika file config belum tersedia atau nilainya kosong.
DEFAULT_MODEL="${DEFAULT_MODEL:-gemma4:e4b}"
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

# Model selalu dikunci ke DEFAULT_MODEL dari config.
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
  local service_host

  if service_host=$(read_ollama_service_env "OLLAMA_HOST"); then
    normalize_ollama_host_url "$service_host"
    return 0
  fi

  normalize_ollama_host_url ""
}

OLLAMA_BASE_URL="$(resolve_ollama_base_url)"

# URLs turunan (harus setelah config)
OLLAMA_API_URL="${OLLAMA_BASE_URL}/api/chat"
OLLAMA_TAGS_URL="${OLLAMA_BASE_URL}/api/tags"

# ===== Warna Output (auto disable jika non-tty / NO_COLOR) =====
IS_TTY=0
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  IS_TTY=1
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
success() { echo -e "${GREEN}$*${NC}" 1>&2; }
warn()    { echo -e "${YELLOW}$*${NC}" 1>&2; }
err()     { echo -e "${RED}$*${NC}" 1>&2; }
die()     { err "Error: $*"; live_status_stop 2>/dev/null || true; spinner_stop 2>/dev/null; exit 1; }
dbg()     { if [[ "${DEBUG}" -eq 1 ]]; then echo -e "${CYAN}[debug]${NC} $*" 1>&2; fi; }

refresh_ollama_urls() {
  OLLAMA_API_URL="${OLLAMA_BASE_URL}/api/chat"
  OLLAMA_TAGS_URL="${OLLAMA_BASE_URL}/api/tags"
}

preselect_ollama_model_for_banner() {
  OLLAMA_MODEL="$DEFAULT_MODEL"
}

# ===== UI / Animasi Utilities =====
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
    printf '%d detik' "$diff"
  fi
}

spinner_start() {
  local msg="${1:-Memproses...}"
  [[ "$IS_TTY" -eq 1 ]] || return 0
  live_status_stop 2>/dev/null || true
  spinner_stop
  (
    local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local i=0 len=${#chars}
    printf '\033[?25l' >&2
    while true; do
      printf '\r  %b%s%b %s' "$CYAN" "${chars:i%len:1}" "$NC" "$msg" >&2
      i=$((i + 1))
      sleep 0.08
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
  local msg="${1:-Memproses...}"
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
  local msg="${1:-Memproses...}"
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
  local msg="${1:-Memproses...}"
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
    live_status_update "${LIVE_STATUS_LAST_MSG:-Memproses...}"
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
  local current="$1" total="$2" label="${3:-Memproses}" elapsed="${4:-}"
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

progress_bar() {
  local current="$1" total="$2" label="${3:-}"
  [[ "$IS_TTY" -eq 1 ]] || return 0
  [[ "$total" -gt 0 ]] || return 0
  local width=10
  local filled=$((current * width / total))
  local bar="" i
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=filled; i<width; i++)); do bar+="░"; done
  printf '\r  %b[%s]%b %d/%d %s' "$CYAN" "$bar" "$NC" "$current" "$total" "$label" >&2
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
  echo -e "${GREEN}✅ Selesai dalam ${elapsed_text}${NC}" >&2
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

Auto stage → AI commit message (Ollama) → commit → push.
Output commit message:
  - Baris 1: subject singkat tanpa body/footer

Options:
  -h, --help                  Tampilkan bantuan
  -v, --version               Tampilkan versi
  -s, --status                Tampilkan git status saja
  -n, --no-push               Commit tanpa push
  -p, --patch                 Staging interaktif (git add -p)
  -i, --interactive           Tampilkan commit message dan minta konfirmasi sebelum commit
      --no-stage              Jangan staging otomatis
      --dry-run               Hanya tampilkan commit message (tanpa ubah git state)
      --debug                 Tampilkan log debug
      --force-diff            Tetap kirim diff ke AI walau terdeteksi pola sensitif
      --no-file-analysis      Matikan analisis per-file (lebih cepat)
      --file-analysis-limit N Batasi jumlah file untuk analisis per-file (default: ${FILE_ANALYSIS_LIMIT})
      --file-analysis-parallelism N
                              Jumlah request analisis file paralel (default: ${FILE_ANALYSIS_PARALLELISM})
      --no-structured         Matikan structured output (fallback ke plain text)
      --no-pull               Jangan auto-pull model jika tidak ada
      --no-banner             Jangan tampilkan banner awal
      --no-verify             Git commit tanpa menjalankan hooks (git commit --no-verify)

Config:
  ${SCRIPT_CONFIG_FILE}

Config variables:
  DEFAULT_MODEL               Model Ollama yang selalu dipakai
  AI_TEMPERATURE              Default ${AI_TEMPERATURE}
  AI_THINK                    Default false (opsi: false|true|low|medium|high)
  AI_NUM_PREDICT              Token output request (maks: ${AI_MAX_NUM_PREDICT})
  AI_MAX_NUM_PREDICT          Batas maksimum num_predict
  FILE_ANALYSIS_NUM_PREDICT_PER_FILE
                              Token output analisis per file (default: ${FILE_ANALYSIS_NUM_PREDICT_PER_FILE})
  FILE_ANALYSIS_PARALLELISM   Jumlah request analisis file paralel (default: ${FILE_ANALYSIS_PARALLELISM})

Ollama service:
  Host/runtime Ollama mengikuti ${OLLAMA_SERVICE_FILE}.
HELP
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)            show_help; exit 0 ;;
      -v|--version)         echo "git-ai version $VERSION"; exit 0 ;;
      -s|--status)          check_git_repo; git status; exit 0 ;;
      -n|--no-push)         DO_PUSH=0; shift ;;
      -m|--model)           die "-m/--model tidak didukung. Ubah DEFAULT_MODEL di ${SCRIPT_CONFIG_FILE}." ;;
      -p|--patch)           USE_PATCH=1; shift ;;
      -i|--interactive)     INTERACTIVE=1; shift ;;
      --no-stage)           DO_STAGE=0; shift ;;
      --dry-run)            DRY_RUN=1; shift ;;
      --debug)              DEBUG=1; shift ;;
      --force-diff)         FORCE_DIFF=1; shift ;;
      --no-file-analysis)   DO_FILE_ANALYSIS=0; shift ;;
      --file-analysis-limit)
                            [[ $# -ge 2 ]] || die "--file-analysis-limit butuh angka"
                            [[ "$2" =~ ^[0-9]+$ ]] || die "--file-analysis-limit harus angka non-negatif"
                            FILE_ANALYSIS_LIMIT="$2"; shift 2 ;;
      --file-analysis-parallelism)
                            [[ $# -ge 2 ]] || die "--file-analysis-parallelism butuh angka"
                            [[ "$2" =~ ^[0-9]+$ ]] || die "--file-analysis-parallelism harus angka >= 1"
                            [[ "$2" -ge 1 ]] || die "--file-analysis-parallelism harus angka >= 1"
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
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Bukan git repository"
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
  dbg "Dry-run index aktif: $DRY_RUN_INDEX_FILE"
}

cleanup_dry_run_index() {
  if [[ -n "${DRY_RUN_INDEX_FILE:-}" ]]; then
    rm -f "$DRY_RUN_INDEX_FILE" || true
    unset GIT_INDEX_FILE || true
    DRY_RUN_INDEX_FILE=""
  fi
}

check_deps() {
  show_step "Memeriksa dependensi"

  for cmd in git curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' tidak ditemukan. Install dulu."
  done
  step_ok "git, curl, jq tersedia"

  if [[ ! "$FILE_ANALYSIS_LIMIT" =~ ^[0-9]+$ ]] || [[ "$FILE_ANALYSIS_LIMIT" -lt 0 ]]; then
    die "FILE_ANALYSIS_LIMIT harus angka non-negatif."
  fi
  if [[ ! "$FILE_ANALYSIS_NUM_PREDICT_PER_FILE" =~ ^[0-9]+$ ]] || [[ "$FILE_ANALYSIS_NUM_PREDICT_PER_FILE" -lt 1 ]]; then
    die "FILE_ANALYSIS_NUM_PREDICT_PER_FILE harus angka >= 1."
  fi
  if [[ ! "$FILE_ANALYSIS_PARALLELISM" =~ ^[0-9]+$ ]] || [[ "$FILE_ANALYSIS_PARALLELISM" -lt 1 ]]; then
    die "FILE_ANALYSIS_PARALLELISM harus angka >= 1."
  fi
  if [[ -n "$AI_NUM_PREDICT" ]] && [[ ! "$AI_NUM_PREDICT" =~ ^[0-9]+$ ]]; then
    die "AI_NUM_PREDICT harus angka."
  fi
  if [[ ! "$AI_MAX_NUM_PREDICT" =~ ^[0-9]+$ ]] || [[ "$AI_MAX_NUM_PREDICT" -lt 1 ]]; then
    die "AI_MAX_NUM_PREDICT harus angka >= 1."
  fi
  if [[ -n "$AI_NUM_PREDICT" && "$AI_NUM_PREDICT" -gt "$AI_MAX_NUM_PREDICT" ]]; then
    warn "AI_NUM_PREDICT melebihi ${AI_MAX_NUM_PREDICT}; memakai batas maksimum."
    AI_NUM_PREDICT="$AI_MAX_NUM_PREDICT"
  fi
  if [[ "$FILE_ANALYSIS_NUM_PREDICT_PER_FILE" -gt "$AI_MAX_NUM_PREDICT" ]]; then
    warn "FILE_ANALYSIS_NUM_PREDICT_PER_FILE melebihi ${AI_MAX_NUM_PREDICT}; memakai batas maksimum."
    FILE_ANALYSIS_NUM_PREDICT_PER_FILE="$AI_MAX_NUM_PREDICT"
  fi
  if [[ ! "$AI_TEMPERATURE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    die "AI_TEMPERATURE harus angka (contoh 0.2)."
  fi
  if [[ ! "$AI_THINK" =~ ^(false|true|low|medium|high)$ ]]; then
    die "AI_THINK harus salah satu: false, true, low, medium, high."
  fi

  spinner_start "Menghubungi Ollama di ${OLLAMA_BASE_URL}..."
  local tags_json
  if ! tags_json=$(curl -sSf --max-time 10 "$OLLAMA_TAGS_URL" 2>/dev/null); then
    spinner_stop
    die "Ollama tidak dapat diakses di $OLLAMA_BASE_URL (tags). Pastikan service berjalan dan ${OLLAMA_SERVICE_FILE} benar."
  fi
  spinner_stop

  local available_models
  available_models=$(jq -r '.models[].name' <<<"$tags_json" 2>/dev/null | sed '/^$/d' || true)

  OLLAMA_MODEL="$DEFAULT_MODEL"
  step_info "Model dari DEFAULT_MODEL: ${OLLAMA_MODEL}"

  if ! printf '%s\n' "$available_models" | grep -Fxq -- "$OLLAMA_MODEL"; then
    warn "Model DEFAULT_MODEL '$OLLAMA_MODEL' tidak ditemukan."

    if [[ "$NO_PULL" -eq 1 ]]; then
      die "Model '$OLLAMA_MODEL' tidak ada di server dan --no-pull aktif. Pull dulu: ollama pull $OLLAMA_MODEL"
    fi
    if command -v ollama >/dev/null 2>&1; then
      warn "Pulling DEFAULT_MODEL: $OLLAMA_MODEL..."
      OLLAMA_HOST="$OLLAMA_BASE_URL" ollama pull "$OLLAMA_MODEL"
    else
      die "Model '$OLLAMA_MODEL' tidak ada di server dan CLI 'ollama' tidak ditemukan untuk melakukan pull."
    fi
  fi
  step_ok "Model ${OLLAMA_MODEL} aktif di Ollama"
}

has_any_changes() {
  ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]
}

has_staged_changes() {
  ! git diff --cached --quiet
}

stage_changes() {
  show_step "Staging perubahan"

  if ! has_any_changes; then
    warn "Tidak ada perubahan untuk di-commit."
    exit 0
  fi

  if [[ "$DO_STAGE" -eq 0 ]]; then
    if ! has_staged_changes; then
      die "Kamu memilih --no-stage, tapi belum ada staged changes. Jalankan git add dulu."
    fi
    step_ok "Menggunakan staged changes yang sudah ada"
    return 0
  fi

  if [[ "$USE_PATCH" -eq 1 ]]; then
    git add -p
  else
    git add -A
  fi

  if ! has_staged_changes; then
    warn "Tidak ada staged changes setelah proses staging."
    exit 0
  fi

  local staged_count
  staged_count=$(git diff --cached --name-only | wc -l)
  local stage_method="git add -A"
  [[ "$USE_PATCH" -eq 1 ]] && stage_method="git add -p"
  step_ok "${staged_count} file di-stage (${stage_method})"
}

sensitive_pattern_regex() {
  cat <<'EOF'
((password|passwd|secret|api[_-]?key|token|auth)[[:space:]]*['"]?[:=]['"]?[[:space:]]*['"][A-Za-z0-9_\\-]{8,}['"]|BEGIN [A-Z]+ PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pous]_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z\\-_]{35})
EOF
}

has_sensitive_patterns() {
  local content="$1"
  grep -Eiq "$(sensitive_pattern_regex)" <<<"$content"
}

detect_sensitive_patterns() {
  local sample
  sample=$(git diff --cached --no-color | head -c 100000 || true)

  has_sensitive_patterns "$sample"
}

collect_top_files() {
  local tmp
  tmp=$(mktemp)
  # Pastikan temp file dibersihkan meski fungsi gagal di tengah jalan
  trap 'rm -f "$tmp"' RETURN
  while IFS=$'\t' read -r add del path; do
    [[ -z "${path:-}" ]] && continue
    [[ "${add:-0}" == "-" ]] && add=0
    [[ "${del:-0}" == "-" ]] && del=0
    local total=$((add + del))
    printf "%s\t%s\n" "$total" "$path" >> "$tmp"
  done < <(git diff --cached --numstat || true)

  sort -nrk1,1 "$tmp" | head -n "$TOP_FILES" | cut -f2- || true
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
  local out="" status path1 path2

  while IFS=$'\t' read -r status path1 path2; do
    [[ -z "${status:-}" || -z "${path1:-}" ]] && continue

    case "$status" in
      R*) out+="Rename: ${path1} -> ${path2}"$'\n' ;;
      C*) out+="Copy: ${path1} -> ${path2}"$'\n' ;;
      D)  out+="Delete: ${path1}"$'\n' ;;
      A)  out+="Add: ${path1}"$'\n' ;;
      M)  out+="Modify: ${path1}"$'\n' ;;
      *)  out+="${status}: ${path1}"$'\n' ;;
    esac
  done < <(git diff --cached --name-status -M | head -n "$MAX_FILES_LIST" || true)

  printf '%s' "$out"
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
    src|lib|app|bin|cmd|pkg|test|tests|spec|docs|doc|the|and|untuk|yang|dan|file|utils)
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
      *config*) add_change_focus_term "konfigurasi" ;;
      *schema*) add_change_focus_term "schema" ;;
      *migration*) add_change_focus_term "migrasi" ;;
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

classify_change_context() {
  local status path1 path2 path

  HAS_DELETE=0
  HAS_RENAME=0
  HAS_CONFIG_CHANGE=0
  HAS_SCHEMA_API_DB_CHANGE=0
  HAS_CODE_CHANGE=0
  HAS_DOC_CHANGE=0
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
        add_path_focus_terms "$path1"
        add_path_focus_terms "$path"
        ;;
      D)
        HAS_DELETE=1
        path="$path1"
        [[ -n "$DELETE_FOCUS_LABEL" ]] || DELETE_FOCUS_LABEL=$(path_subject_label "$path")
        add_path_focus_terms "$path"
        ;;
      A)
        path="$path1"
        add_path_focus_terms "$path"
        ;;
      *)
        path="$path1"
        add_path_focus_terms "$path"
        ;;
    esac

    is_doc_path "$path" && HAS_DOC_CHANGE=1
    is_config_path "$path" && HAS_CONFIG_CHANGE=1
    is_schema_api_db_path "$path" && HAS_SCHEMA_API_DB_CHANGE=1
    is_code_path "$path" && HAS_CODE_CHANGE=1
  done < <(git diff --cached --name-status -M | head -n "$MAX_FILES_LIST" || true)

  if grep -Eq '[A-Z][A-Z0-9_]{2,}|\.service|\.env|\.ya?ml|\.toml|\.json' <<<"${DIFF_TERMS:-}"; then
    HAS_CONFIG_CHANGE=1
  fi

  local term
  while IFS= read -r term; do
    add_change_focus_term "$term"
  done < <(printf '%s\n' "${DIFF_TERMS:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d')
}

build_change_priority_hint() {
  local hints=()

  [[ "${HAS_DELETE:-0}" -eq 1 ]] && hints+=("delete file: ${DELETE_FOCUS_LABEL:-file}")
  [[ "${HAS_RENAME:-0}" -eq 1 ]] && hints+=("rename/move file: ${RENAME_FOCUS_LABEL:-file}")
  [[ "${HAS_CONFIG_CHANGE:-0}" -eq 1 ]] && hints+=("config/runtime/service/env")
  [[ "${HAS_SCHEMA_API_DB_CHANGE:-0}" -eq 1 ]] && hints+=("API/schema/database")
  [[ "${HAS_CODE_CHANGE:-0}" -eq 1 ]] && hints+=("kode/logika")
  [[ "${HAS_DOC_CHANGE:-0}" -eq 1 ]] && hints+=("dokumentasi")

  if [[ "${#hints[@]}" -eq 0 ]]; then
    printf 'perubahan file staged'
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
  CHANGE_PRIORITY_HINT=$(build_change_priority_hint)
  FILES_CHANGED=$(git diff --cached --name-only | head -n "$MAX_FILES_LIST" | tr '\n' ', ' | sed 's/, $//' || true)
  if [[ "$safe_mode" -eq 1 ]]; then
    TOP_HUNKS=""
  else
    TOP_HUNKS=$(collect_top_hunks)
  fi
}

# ===== Per-File Analysis =====
SYSTEM_PROMPT_FILE_ANALYSIS_BATCH='Kamu adalah penganalisis git diff. Analisis setiap file secara terpisah dalam Bahasa Indonesia. Output wajib JSON valid sesuai schema. Untuk setiap file, isi "file" dengan nama file persis dari input dan "analysis" dengan 1-2 kalimat jelas: sebutkan perubahan utama, konteks penting, dan dampaknya terhadap repo. Jangan pakai markdown dan jangan beri jawaban umum.'

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

  prompt='Analisis diff berikut per file. Kembalikan JSON dengan array "files" sesuai urutan input. Wajib ada satu item untuk setiap [FILE]. Buat analysis spesifik berdasarkan diff, bukan jawaban umum.'

  for ((i=start; i<end; i++)); do
    prompt+=$'\n\n[FILE]\n'"${BATCH_ANALYSIS_FILE_NAMES[$i]}"
    prompt+=$'\n[DIFF]\n'"${BATCH_ANALYSIS_DIFF_CHUNKS[$i]}"$'\n[/DIFF]'
  done

  printf '%s' "$prompt"
}

build_file_analysis_batch_label() {
  local start="$1"
  local count="$2"
  local end=$((start + count))
  local i label=""

  for ((i=start; i<end; i++)); do
    label+="${BATCH_ANALYSIS_FILE_NAMES[$i]}, "
  done

  printf '%s' "${label%, }"
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

  if content=$(ollama_chat "$SYSTEM_PROMPT_FILE_ANALYSIS_BATCH" "$prompt" "$schema" 60 1 "$batch_num_predict") \
    && json=$(printf '%s' "$content" | jq -e . 2>/dev/null); then
    printf '%s\n' "$json" > "$output_file"
    dbg "Batch analisis ${batch_no} selesai (${count} file)"
    return 0
  fi

  printf '{"files":[]}\n' > "$output_file"
  dbg "Batch analisis ${batch_no} gagal; memakai fallback per file"
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
  local sensitive_files_skipped=0
  local chunk
  for chunk in "${DIFF_CHUNKS[@]}"; do
    if [[ "$FORCE_DIFF" -eq 0 ]] && has_sensitive_patterns "$chunk"; then
      sensitive_files_skipped=$((sensitive_files_skipped + 1))
      continue
    fi

    safe_chunks+=("$chunk")
  done

  local safe_total=${#safe_chunks[@]}
  if [[ "$safe_total" -eq 0 ]]; then
    if [[ "$sensitive_files_skipped" -gt 0 ]]; then
      step_info "  ⟩ Melewati ${sensitive_files_skipped} file sensitif; tidak ada file aman untuk analisis per-file."
    fi
    return 1
  fi

  local limit="$FILE_ANALYSIS_LIMIT"
  [[ "$limit" -le 0 ]] && return 1
  [[ "$limit" -gt "$safe_total" ]] && limit="$safe_total"

  local analysis_indices=()
  mapfile -t analysis_indices < <(build_analysis_indices "$safe_total" "$limit")

  dbg "Menganalisis per-file: total $total_files, aman $safe_total, sensitif $sensitive_files_skipped, limit $limit, sampel: ${analysis_indices[*]}"

  FILE_ANALYSES=""
  local analysis_total=${#analysis_indices[@]}
  local analysis_start
  analysis_start=$(date +%s)

  BATCH_ANALYSIS_FILE_NAMES=()
  BATCH_ANALYSIS_DIFF_CHUNKS=()

  local selected_index file_name truncated_chunk
  for selected_index in "${analysis_indices[@]}"; do
    chunk="${safe_chunks[$((selected_index - 1))]}"

    file_name=$(echo "$chunk" | head -n 1 | sed -e 's#.* b/##')
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
    step_info "  ⟩ Melewati ${sensitive_files_skipped} file sensitif; menganalisis ${analysis_total} file aman."
  fi
  local status_msg
  status_msg=$(progress_status_text 0 "$analysis_total" "Menganalisis file AI")
  live_status_start "$status_msg" "Mengirim ${analysis_total} file ke AI (blocking, paralel ${parallelism})..."

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
        analysis="Perubahan pada file $file_name"
      fi

      analysis_results[i]="$analysis"
      [[ "$status" -ne 0 ]] && failed_batches=$((failed_batches + 1))

      status_msg=$(progress_status_text "$completed" "$analysis_total" "Menganalisis file AI" "$(elapsed_since "$analysis_start")")
      live_status_update "$status_msg"
      live_status_print_above "  ${GREEN}→${NC} ${BOLD}${file_name}${NC}: ${DIM}${analysis}${NC}"
    done

    [[ "$completed" -ge "$analysis_total" ]] && break
    status_msg=$(progress_status_text "$completed" "$analysis_total" "Menganalisis file AI" "$(elapsed_since "$analysis_start")")
    live_status_update "$status_msg"
    [[ "$made_progress" -eq 1 ]] || sleep 0.2
  done

  live_status_stop

  FILE_ANALYSES=""
  for ((i=0; i<analysis_total; i++)); do
    file_name="${BATCH_ANALYSIS_FILE_NAMES[$i]}"
    analysis="${analysis_results[$i]:-Perubahan pada file $file_name}"
    FILE_ANALYSES+=$'<file name="'${file_name}$'">\n'${analysis}$'\n</file>\n'
  done

  rm -f "${batch_output_files[@]}" "${batch_status_files[@]}"

  local analysis_elapsed
  analysis_elapsed=$(elapsed_since "$analysis_start")
  if [[ "$failed_batches" -gt 0 ]]; then
    if [[ "$sensitive_files_skipped" -gt 0 ]]; then
      step_ok "Analisis ${analysis_total} dari ${safe_total} file aman selesai dengan ${failed_batches} fallback; ${sensitive_files_skipped} file sensitif dilewati (${analysis_elapsed})"
    else
      step_ok "Analisis ${analysis_total} dari ${total_files} file selesai dengan ${failed_batches} fallback (${analysis_elapsed})"
    fi
  else
    if [[ "$sensitive_files_skipped" -gt 0 ]]; then
      step_ok "Analisis ${analysis_total} dari ${safe_total} file aman selesai; ${sensitive_files_skipped} file sensitif dilewati (${analysis_elapsed})"
    else
      step_ok "Analisis ${analysis_total} dari ${total_files} file selesai (${analysis_elapsed})"
    fi
  fi
}

# ===== Prompt Builder =====
build_system_prompt_text() {
  cat <<EOF
Kamu adalah senior software engineer.

Tugasmu: buat 1 baris subject commit dalam Bahasa Indonesia.

Aturan:
1) Output WAJIB 1 baris plain text (tanpa markdown, tanpa JSON, tanpa code block).
2) Jangan gunakan prefix conventional commit (feat/fix/docs/dll), cukup kalimat inti.
3) Subject harus ringkas dan spesifik.
4) Jangan menulis body atau footer.
5) Jangan akhiri subject dengan tanda titik.
6) Utamakan tema prioritas dari Git: delete/rename, config/runtime/service/env, API/schema/database, kode/logika, lalu dokumentasi.
7) Hindari istilah generik seperti "struktur proyek" atau "perubahan umum"; gunakan istilah konkret dari diff.
dan ingat selalu gunakan Bahasa Indonesia.
EOF
}

build_system_prompt_json() {
  cat <<EOF
Kamu adalah senior software engineer.

Isi field berikut berdasarkan perubahan yang diberikan:
- subject (wajib): 1 baris, Bahasa Indonesia, ringkas, spesifik, tanpa titik di akhir.

Dilarang menulis body/footer. Hanya subject.
Utamakan fakta dari Git: delete/rename, config/runtime/service/env, API/schema/database, kode/logika, lalu dokumentasi. Hindari istilah generik; gunakan istilah konkret dari path, module, service, env var, schema, API, atau file jika relevan.
dan ingat selalu gunakan Bahasa Indonesia.
EOF
}

build_user_prompt() {
  local safe_mode="$1"

  local prompt
  prompt="Analisis perubahan berikut dan buat commit message yang paling tepat dan ingat selalu gunakan Bahasa Indonesia.

[PERUBAHAN PRIORITAS DARI GIT]
${GIT_PRIORITY_CHANGES}

[PRIORITAS TEMA UNIVERSAL]
${CHANGE_PRIORITY_HINT}

[NAME-STATUS]
${NAME_STATUS}

[GIT SUMMARY]
${GIT_SUMMARY}

[STAT]
${STAT}

[ISTILAH KONKRET DARI DIFF]
${DIFF_TERMS}

[ATURAN PEMILIHAN SUBJECT]
- Utamakan perubahan eksplisit dari [PERUBAHAN PRIORITAS DARI GIT].
- Gunakan [PRIORITAS TEMA UNIVERSAL] untuk memilih tema commit.
- Jangan ganti delete/rename/config/API/schema/kode dengan istilah generik.
- Jangan tulis domain spesifik seperti GPU, database, API, schema, atau service kecuali terlihat di diff/path.
- Hindari \"struktur proyek\", \"pembaruan umum\", atau \"berbagai perubahan\" jika ada istilah konkret.
- Gunakan kata sambung \"dan\", bukan simbol \"&\".
- Jika banyak perubahan, rangkum maksimal 2 tema paling penting.
- Prioritas tema: delete/rename/move file > config/runtime/service/env > API/schema/database > kode/logika > dokumentasi."

  if [[ -n "${FILE_ANALYSES:-}" ]]; then
    prompt+=$'\n\n[ANALISIS PER-FILE]\n'"$FILE_ANALYSES"
  elif [[ "$safe_mode" -eq 0 ]]; then
    prompt+=$'\n\n[DIFF DETAIL]\n'"$TOP_HUNKS"
  else
    prompt+=$'\n\nCatatan: Safe mode aktif, tidak mengirim diff detail.'
  fi

  prompt+=$'\n\nBerikan output sesuai aturan.'
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
  grep -Eiq 'hapus|delete|remove|pindah|rename|move|migrasi|bersih|buang|ganti|replace|arsip|hapuskan' <<<"$lower"
}

subject_mentions_config_change() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  grep -Eiq 'konfigurasi|config|setting|service|runtime|env|variabel|paralel|timeout|limit|opsi|server|deploy|deployment' <<<"$lower"
}

subject_mentions_schema_api_db_change() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  grep -Eiq 'api|schema|skema|database|db|migrasi|query|endpoint|route|proto|graphql|sql|model data' <<<"$lower"
}

subject_mentions_doc_change() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  grep -Eiq 'dokumen|dokumentasi|panduan|readme|runbook|protokol|instruksi|catatan|docs' <<<"$lower"
}

commit_subject_quality_issue() {
  local subject="$1"
  local lower evidence_blob
  lower=$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]')
  evidence_blob="${GIT_PRIORITY_CHANGES}${DIFF_TERMS}${TOP_HUNKS}${FILE_ANALYSES}${CHANGE_PRIORITY_HINT}"

  if grep -Eq '&' <<<"$subject"; then
    printf 'Subject memakai gaya kurang rapi; gunakan kata sambung "dan", bukan simbol "&".'
    return 0
  fi

  if grep -Eq 'struktur[[:space:]-]*proyek|pembaruan umum|perubahan umum|berbagai perubahan|beberapa perubahan' <<<"$lower"; then
    printf 'Subject terlalu generik; gunakan tema konkret dari Git seperti delete/rename, config/runtime, API/schema/database, kode, atau dokumentasi.'
    return 0
  fi

  if grep -Eq 'gpu|cuda|nvidia|rocm' <<<"$lower" && ! grep -Eiq 'gpu|cuda|nvidia|rocm' <<<"$evidence_blob"; then
    printf 'Subject menyebut GPU/hardware, tetapi sinyal itu tidak terlihat di diff/path; gunakan istilah konkret yang ada di Git.'
    return 0
  fi

  if [[ "${HAS_DELETE:-0}" -eq 1 || "${HAS_RENAME:-0}" -eq 1 ]]; then
    if subject_mentions_structural_change "$subject" || subject_matches_change_focus "$subject"; then
      return 1
    fi
    printf 'Subject belum membawa tema delete/rename file, padahal itu tema prioritas tertinggi.'
    return 0
  fi

  if [[ "${HAS_CONFIG_CHANGE:-0}" -eq 1 ]]; then
    if subject_mentions_config_change "$subject" || subject_matches_change_focus "$subject"; then
      return 1
    fi
    printf 'Subject belum membawa tema config/runtime/service/env, padahal itu tema prioritas tertinggi yang tersedia.'
    return 0
  fi

  if [[ "${HAS_SCHEMA_API_DB_CHANGE:-0}" -eq 1 ]]; then
    if subject_mentions_schema_api_db_change "$subject" || subject_matches_change_focus "$subject"; then
      return 1
    fi
    printf 'Subject belum membawa tema API/schema/database, padahal itu tema prioritas tertinggi yang tersedia.'
    return 0
  fi

  if [[ "${HAS_DOC_CHANGE:-0}" -eq 1 && "${HAS_CODE_CHANGE:-0}" -eq 0 ]]; then
    if subject_mentions_doc_change "$subject" || subject_matches_change_focus "$subject"; then
      return 1
    fi
    printf 'Subject belum membawa tema dokumentasi/panduan, padahal perubahan hanya dokumentasi.'
    return 0
  fi

  return 1
}

build_quality_retry_prompt() {
  local base_prompt="$1"
  local previous_subject="$2"
  local issue="$3"

  cat <<EOF
${base_prompt}

[KOREKSI SUBJECT SEBELUMNYA]
Subject sebelumnya:
${previous_subject}

Masalah:
${issue}

Tulis ulang subject menjadi lebih akurat, konkret, dan tetap ringkas.
Ikuti prioritas tema universal: delete/rename/move file > config/runtime/service/env > API/schema/database > kode/logika > dokumentasi.
Berikan HANYA 1 baris subject commit tanpa markdown, tanpa JSON tambahan, tanpa body/footer.
EOF
}

ollama_request() {
  local payload="$1"

  local tmp_body tmp_err http_code body err_txt
  tmp_body=$(mktemp)
  tmp_err=$(mktemp)

  local max_time="${2:-120}"
  http_code=$(curl -sS --connect-timeout 5 --max-time "$max_time" \
    -o "$tmp_body" -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$OLLAMA_API_URL" 2>"$tmp_err" || true)

  body=$(cat "$tmp_body" || true)
  err_txt=$(cat "$tmp_err" || true)
  rm -f "$tmp_body" "$tmp_err"

  if [[ -z "$http_code" ]]; then
    dbg "curl error: ${err_txt:-<none>}"
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
    dbg "num_predict ${num_predict} melebihi batas ${AI_MAX_NUM_PREDICT}; memakai batas maksimum."
    num_predict="$AI_MAX_NUM_PREDICT"
  fi

  printf '%s' "$num_predict"
}

ollama_chat() {
  local system_prompt="$1"
  local user_prompt="$2"
  local format_json_schema="${3:-}"   # kosong = non-structured
  local max_time="${4:-120}"          # timeout curl (default 120s)
  # Argumen ke-5 dari versi lama tetap diterima, tetapi diabaikan.
  local num_predict_override="${6:-}" # kosong = pakai AI_NUM_PREDICT

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

  # Default nothink: kirim kontrol think ke Ollama.
  payload=$(jq -c \
    --arg think "$AI_THINK" \
    '. + {think: (if $think == "true" then true elif $think == "false" then false else $think end)}' \
    <<<"$payload")

  dbg "Ollama model: ${OLLAMA_MODEL}"
  dbg "Ollama options: $(jq -c '.options' <<<"$payload" 2>/dev/null || printf '{}')"
  dbg "Payload size: ${#payload} chars"

  _ollama_chat_blocking "$payload" "$max_time"
}

_ollama_chat_blocking() {
  local payload="$1"
  local max_time="$2"

  # Pastikan Ollama mengembalikan satu response utuh.
  local blocking_payload
  blocking_payload=$(jq -c '.stream = false' <<<"$payload")

  local resp text
  resp=$(ollama_request "$blocking_payload" "$max_time")
  dbg "Ollama response (truncated): $(echo "$resp" | head -c 300)"

  echo "$resp" | jq -e . >/dev/null 2>&1 || return 1
  local prompt_tokens eval_tokens
  prompt_tokens=$(echo "$resp" | jq -r '.prompt_eval_count // 0' 2>/dev/null || echo 0)
  eval_tokens=$(echo "$resp" | jq -r '.eval_count // 0' 2>/dev/null || echo 0)
  if [[ -f "${TOKEN_LOG_FILE:-}" ]]; then
    echo "$((prompt_tokens + eval_tokens))" >> "$TOKEN_LOG_FILE"
  fi
  dbg "Ollama usage: prompt_eval_count=$prompt_tokens, eval_count=$eval_tokens"
  text=$(echo "$resp" | jq -r '.message.content // empty' 2>/dev/null || true)
  [[ -z "$text" ]] && return 1
  printf '%s' "$text"
}

validate_commit_subject() {
  local subject="$1"
  [[ -n "$subject" ]] || return 1
  [[ "${#subject}" -ge 8 ]] || return 1
  # Tolak control character (0x00-0x1f, 0x7f), bukan semua non-ASCII.
  # Bahasa Indonesia umumnya ASCII, tapi biarkan UTF-8 valid lolos.
  if printf '%s' "$subject" | LC_ALL=C grep -qP '[\x00-\x1f\x7f]'; then
    return 1
  fi
  # Hanya tolak subject yang berakhir titik (konvensi commit message).
  # Tanda baca lain seperti ), >, dll diizinkan.
  if echo "$subject" | grep -Eq '\.$'; then
    return 1
  fi
  echo "$subject" | grep -Eq '^[[:space:]]*[^[:space:]].*$'
}

normalize_commit_subject() {
  local subject="$1"

  subject=$(printf '%s' "$subject" | sed -E 's/[[:space:]]*&[[:space:]]*/ dan /g')
  subject=$(printf '%s' "$subject" | sed -E 's/(^|[[:space:]])[Uu]pdate([[:space:]]|$)/\1Perbarui\2/g')
  subject=$(printf '%s' "$subject" | sed -E 's/^Pembaruan([[:space:]]|$)/Perbarui\1/g')
  subject=$(printf '%s' "$subject" | sed -E 's/[Bb]atas [Pp]arallel([[:space:]]|$)/batas paralel\1/g; s/[Bb]atas [Pp]aralel([[:space:]]|$)/batas paralel\1/g')
  subject=$(printf '%s' "$subject" | sed -E 's/[Pp]arallelisme/paralelisme/g; s/[Pp]aralellisme/paralelisme/g; s/[Pp]arallel([[:space:]]|$)/paralel\1/g')
  subject=$(printf '%s' "$subject" | tr -s ' ')
  subject=$(printf '%s' "$subject" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

  printf '%s' "$subject"
}

clean_plain_commit_message() {
  local msg="$1"

  msg=$(echo "$msg" | sed "s/^\`\`\`.*//g; s/\`\`\`$//g")
  local subject
  subject=$(echo "$msg" | sed '/^[[:space:]]*$/d' | head -n 1 | sed 's/\*\*//g; s/\*//g; s/`//g')
  subject=$(echo "$subject" | sed -E 's/^[[:space:]]*[-*]+[[:space:]]*//')
  subject=$(echo "$subject" | tr -s ' ')
  subject=$(echo "$subject" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[\.[:space:]]*$//')
  subject=$(normalize_commit_subject "$subject")

  printf '%s' "$subject"
}

compose_commit_message() {
  local subject="$1"

  printf '%s' "$subject"
}

append_fallback_topic() {
  local topic="$1"
  local existing

  for existing in "${FALLBACK_TOPICS[@]}"; do
    [[ "$existing" == "$topic" ]] && return 0
  done

  FALLBACK_TOPICS+=("$topic")
}

build_fallback_subject() {
  FALLBACK_TOPICS=()

  [[ "${HAS_DELETE:-0}" -eq 1 ]] && append_fallback_topic "hapus ${DELETE_FOCUS_LABEL:-file}"
  [[ "${HAS_RENAME:-0}" -eq 1 ]] && append_fallback_topic "pindahkan ${RENAME_FOCUS_LABEL:-file}"
  [[ "${HAS_CONFIG_CHANGE:-0}" -eq 1 ]] && append_fallback_topic "perbarui konfigurasi"
  [[ "${HAS_SCHEMA_API_DB_CHANGE:-0}" -eq 1 ]] && append_fallback_topic "perbarui API/schema"
  [[ "${HAS_CODE_CHANGE:-0}" -eq 1 ]] && append_fallback_topic "perbarui logika kode"
  [[ "${HAS_DOC_CHANGE:-0}" -eq 1 ]] && append_fallback_topic "perbarui dokumentasi"

  local subject
  case "${#FALLBACK_TOPICS[@]}" in
    0)
      subject="Perbarui ${FILES_CHANGED:-beberapa berkas}"
      ;;
    1)
      subject="${FALLBACK_TOPICS[0]}"
      ;;
    2)
      subject="${FALLBACK_TOPICS[0]} dan ${FALLBACK_TOPICS[1]}"
      ;;
    *)
      subject="${FALLBACK_TOPICS[0]}, ${FALLBACK_TOPICS[1]}, dan ${FALLBACK_TOPICS[2]}"
      ;;
  esac

  subject=$(normalize_commit_subject "$subject")

  printf '%s' "$subject"
}

build_commit_schema() {
  jq -n '
    {
      type: "object",
      additionalProperties: false,
      properties: {
        subject: {type:"string"}
      },
      required: ["subject"]
    }
    '
}

compose_commit_from_json() {
  local json="$1"

  local subject
  subject=$(echo "$json" | jq -r '.subject // empty')
  subject=$(echo "$subject" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' )
  subject="${subject//\`/}"
  subject=$(echo "$subject" | tr -s ' ')
  while [[ "$subject" =~ [[:punct:][:space:]]$ ]]; do
    subject="${subject%?}"
  done
  subject=$(normalize_commit_subject "$subject")
  [[ -z "$subject" ]] && return 1

  if ! validate_commit_subject "$subject"; then
    return 1
  fi

  compose_commit_message "$subject"
}

generate_commit_message() {
  # Step headers dipanggil dari main() untuk menghindari subshell counter issue

  local safe_mode=0
  if [[ "$FORCE_DIFF" -eq 0 ]] && detect_sensitive_patterns; then
    safe_mode=1
    warn "Terdeteksi pola sensitif. Safe mode aktif (tidak mengirim diff detail)."
  fi

  collect_context "$safe_mode"
  step_ok "Konteks: ${STAGED_FILE_COUNT} file staged"

  FILE_ANALYSES=""
  if [[ "$DO_FILE_ANALYSIS" -eq 1 ]]; then
    analyze_files_individually || true
  fi

  local attempts=3
  local system_prompt base_user_prompt user_prompt schema content json subject commit_msg quality_issue
  local structured_available="$USE_STRUCTURED_OUTPUT"
  base_user_prompt=$(build_user_prompt "$safe_mode")
  user_prompt="$base_user_prompt"

  local retry_delay=1
  for ((i=1; i<=attempts; i++)); do
    dbg "Attempt $i/$attempts"
    [[ "$i" -gt 1 ]] && {
      step_info "Percobaan ulang $i/$attempts..."
      dbg "Retry delay: ${retry_delay}s"
      sleep "$retry_delay"
      retry_delay=$((retry_delay * 2))
    }

    if [[ "$structured_available" -eq 1 ]]; then
      system_prompt=$(build_system_prompt_json)
      schema=$(build_commit_schema)
      blocking_status_start "Mengirim prompt ke AI model (structured)..."

      if ! content=$(ollama_chat "$system_prompt" "$user_prompt" "$schema"); then
        blocking_status_stop
        dbg "Structured output gagal (request/parse). Fallback ke plain text."
        structured_available=0
        continue
      fi
      blocking_status_stop

      # Ollama mengembalikan JSON sebagai string di message.content
      if ! json=$(printf '%s' "$content" | jq -e . 2>/dev/null); then
        dbg "Structured output bukan JSON valid."
        structured_available=0
        continue
      fi

      if commit_msg=$(compose_commit_from_json "$json"); then
        if quality_issue=$(commit_subject_quality_issue "$commit_msg"); then
          dbg "Subject perlu retry: $quality_issue"
          user_prompt=$(build_quality_retry_prompt "$base_user_prompt" "$commit_msg" "$quality_issue")
          commit_msg=""
          continue
        fi
        break
      fi

      dbg "JSON valid tapi gagal compose/validasi subject."
      structured_available=0
      continue
    fi

    system_prompt=$(build_system_prompt_text)
    blocking_status_start "Mengirim prompt ke AI model (plain text)..."
    if ! content=$(ollama_chat "$system_prompt" "$user_prompt" ""); then
      blocking_status_stop
      continue
    fi
    blocking_status_stop

    subject=$(clean_plain_commit_message "$content")
    if validate_commit_subject "$subject"; then
      commit_msg=$(compose_commit_message "$subject")
      if quality_issue=$(commit_subject_quality_issue "$commit_msg"); then
        dbg "Subject perlu retry: $quality_issue"
        user_prompt=$(build_quality_retry_prompt "$base_user_prompt" "$commit_msg" "$quality_issue")
        commit_msg=""
        continue
      fi
      break
    fi

    user_prompt="${base_user_prompt}"$'\n\n[RETRY]\nOutput kamu sebelumnya tidak valid. Berikan HANYA 1 baris subject commit plain text, tanpa type prefix, tanpa body/footer.'
  done

  if [[ -z "${commit_msg:-}" ]]; then
    warn "Gagal generate subject dari AI. Menggunakan fallback."
    subject=$(build_fallback_subject)
    commit_msg=$(compose_commit_message "$subject")
  fi

  printf '%s' "$commit_msg"
}

do_commit() {
  local msg="$1"
  show_step "Commit"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "DRY RUN: tidak commit/push dan tidak mengubah git state."
    return 0
  fi

  # Interactive mode: tampilkan dan minta konfirmasi
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    info "===== Commit Message ====="
    echo "$msg" >&2
    info "=========================="
    local confirm
    read -rp "Lanjutkan commit? [Y/n/e(dit)] " confirm
    case "${confirm,,}" in
      n|no)  warn "Commit dibatalkan."; exit 0 ;;
      e|edit)
        local tmpfile_edit
        tmpfile_edit=$(mktemp --suffix=.gitcommit)
        printf '%s\n' "$msg" > "$tmpfile_edit"
        ${EDITOR:-vi} "$tmpfile_edit"
        msg=$(cat "$tmpfile_edit")
        rm -f "$tmpfile_edit"
        [[ -z "$(echo "$msg" | sed '/^[[:space:]]*$/d')" ]] && { warn "Commit message kosong. Dibatalkan."; exit 0; }
        ;;
      *)  ;; # default: lanjut
    esac
  fi

  local tmpfile
  tmpfile=$(mktemp)
  printf '%s\n' "$msg" > "$tmpfile"

  if [[ "$NO_VERIFY" -eq 1 ]]; then
    git commit --no-verify -F "$tmpfile"
  else
    git commit -F "$tmpfile"
  fi

  rm -f "$tmpfile"

  local short_hash
  short_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "???")
  step_ok "Committed: ${short_hash}"
}

do_push() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ "$DO_PUSH" -eq 0 ]] && { step_info "Push dilewati (--no-push)"; return 0; }

  show_step "Push"

  local branch remote
  branch=$(git branch --show-current 2>/dev/null || echo "?")

  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    spinner_start "Pushing ke remote..."
    git push
    spinner_stop
    remote=$(git remote | head -n 1 || echo "origin")
    step_ok "Pushed ke ${remote}/${branch}"
    return 0
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    remote="origin"
  else
    remote=$(git remote | head -n 1 || true)
  fi

  if [[ -z "$remote" ]]; then
    warn "Tidak ada remote repository. Skip push."
    return 0
  fi

  spinner_start "Pushing ke ${remote}/${branch}..."
  git push -u "$remote" "$branch"
  spinner_stop
  step_ok "Pushed ke ${remote}/${branch}"
}

acquire_lock() {
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
  LOCK_FILE="${git_dir}/git-ai.lock"
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    die "git-ai sudah berjalan di repo ini. Tunggu proses sebelumnya selesai."
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

  # Hitung total steps berdasarkan konfigurasi
  # Base: deps(1) + stage(2) + analyze+generate(3) + commit(4) + push(5)
  TOTAL_STEPS=5
  [[ "$DO_PUSH" -eq 0 ]] && TOTAL_STEPS=$((TOTAL_STEPS - 1))

  check_deps
  stage_changes

  show_step "Menganalisis & membuat commit message"

  local commit_msg_file
  commit_msg_file=$(mktemp)

  local gen_start
  gen_start=$(date +%s)

  generate_commit_message > "$commit_msg_file"

  local gen_elapsed
  gen_elapsed=$(elapsed_since "$gen_start")
  step_ok "Commit message diterima (${gen_elapsed})"

  local commit_msg
  commit_msg=$(cat "$commit_msg_file")
  rm -f "$commit_msg_file"

  do_commit "$commit_msg"
  do_push

  # Summary akhir
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
        remote=$(git remote | head -n 1 2>/dev/null || echo "origin")
        summary_detail+=" → ${remote}/${branch}"
      fi
    fi
  else
    summary_detail="Mode: dry-run"
  fi
  show_summary "$summary_detail"

  # Hitung total token
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

  # Hasil commit disimpan paling bawah
  echo -e "Commit message \"${commit_msg}\""
  echo -e "${DIM}Token usage ${formatted_tokens}${NC}"
}

main "$@"
