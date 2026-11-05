#!/usr/bin/env bash
# wp-backup.sh — локальный бэкап WordPress + опциональная выгрузка на PBS / S3
# См. TZ_backup_WP.md
set -euo pipefail

SCRIPT_VERSION="2.3.0"
SCRIPT_NAME="$(basename "$0")"

# Exit codes (TZ §6)
E_OK=0
E_ARGS=1
E_DB_CONST=2
E_DUMP=3
E_SITE=4
E_UPLOADS=5
E_SPACE=6
E_REMOTE=7
E_OTHER=10

# Defaults
WP_ROOT=""
WP_CONFIG_EXPLICIT=""
BACKUP_ROOT="/var/backups/wordpress"
SITE_ID=""
MODE="full"
HOT_MONTHS=2
MONTH_NAMES_FILE=""
CHANGED_HOURS=24
DRY_RUN=0
DEBUG="${DEBUG:-0}"
KEEP_RUNS=7
KEEP_CHANGED_RUNS=14
DESTINATION="local"
UPLOAD_CONFIG=""
SKIP_UPLOAD=0
KEEP_LOCAL="yes"
MIN_FREE_GB=5
EXCLUDE_FROM=""
ALLOW_PHP_PARSE=0
UPLOAD_ONLY=0
RUN_DIR=""
UPLOAD_ORDER="PBS_THEN_S3"
NICE_CMD=()

STARTED_AT=""
FINISHED_AT=""
RUN_ID=""
RUN_PATH=""
WP_CONFIG_PATH=""
WP_HOME=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_HOST_RAW=""
DB_HOST=""
DB_PORT=""
STATUS="running"
ERROR_MSG=""
ARTIFACTS=()
NOTES=""
declare -a HOT_REL_DIRS=()
declare -a COLD_REL_DIRS=()
declare -A MONTH_NUM=()
declare -A HOT_YEAR_MONTH=()
LOG_FILE=""
MANIFEST_FILE=""
DEBUG_FILE=""
LAST_STEP=""
LAST_CMD=""
XTRACE_FD=""

UPLOAD_PBS_STATUS="skipped"
UPLOAD_PBS_ERROR=""
UPLOAD_PBS_REMOTE=""
UPLOAD_PBS_FINISHED=""
UPLOAD_S3_STATUS="skipped"
UPLOAD_S3_ERROR=""
UPLOAD_S3_BUCKET=""
UPLOAD_S3_PREFIX=""
UPLOAD_S3_FINISHED=""

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME --wp-root /path/to/server [options]
  $SCRIPT_NAME --upload-only --run-dir /path/to/run --destination pbs|s3|both [options]

Options:
  --wp-root DIR           Absolute path to server directory (required unless --upload-only)
  --wp-config FILE        Explicit wp-config.php path
  --backup-root DIR       Local staging root (default: $BACKUP_ROOT)
  --site-id NAME          Site id under backup-root (default: basename of wp-root)
  --mode MODE             full|db|site|uploads-hot|uploads-cold|uploads-changed|uploads-all
  --hot-months N          Last N calendar months of uploads/YYYY/MM (default: 2)
  --month-names FILE      Extra month folder names: "NAME NUMBER" (1-12)
  --changed-hours N       Changed-files window in hours, whole --wp-root (default: 24)
  --destination DEST      local|pbs|s3|both (default: local)
  --upload-config FILE    Env file with PBS_/S3_ settings
  --skip-upload           Force destination=local for this run
  --keep-local yes|no     Keep local run after successful upload (default: yes)
  --keep-runs N           Retention for full/non-changed runs (default: 7)
  --keep-changed-runs N   Retention for uploads-changed runs (default: 14)
  --min-free-gb N         Abort if free space below N GiB (default: 5)
  --exclude-from FILE     Extra tar exclude patterns
  --allow-php-parse       Fallback PHP parse of wp-config if text parse fails
  --upload-only           Upload existing --run-dir without rebuilding
  --run-dir DIR           Existing run directory for --upload-only
  --dry-run               Print plan only
  --debug                 Verbose diagnostics + bash xtrace (also DEBUG=1)
  -h, --help              Show help
EOF
}

log() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2
  else
    printf '%s\n' "$line" >&2
  fi
  if [[ -n "${DEBUG_FILE:-}" && "$DEBUG_FILE" != "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" >>"$DEBUG_FILE" || true
  fi
}

log_debug() {
  [[ "${DEBUG:-0}" -eq 1 ]] || return 0
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2
  else
    printf '%s\n' "$line" >&2
  fi
  if [[ -n "${DEBUG_FILE:-}" ]]; then
    printf '%s\n' "$line" >>"$DEBUG_FILE" || true
  fi
}

step() {
  LAST_STEP="$*"
  log "STEP: $*"
  log_debug "entering step: $*"
}

mask_secrets() {
  local s="$*"
  if [[ -n "${DB_PASSWORD:-}" ]]; then
    s="${s//$DB_PASSWORD/***}"
  fi
  if [[ -n "${PBS_PASSWORD:-}" ]]; then
    s="${s//$PBS_PASSWORD/***}"
  fi
  if [[ -n "${PBS_API_TOKEN:-}" ]]; then
    s="${s//$PBS_API_TOKEN/***}"
  fi
  if [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    s="${s//$AWS_SECRET_ACCESS_KEY/***}"
  fi
  printf '%s' "$s"
}

dump_debug_context() {
  local code="${1:-?}"
  {
    echo "========== DEBUG CONTEXT =========="
    echo "time: $(date -Iseconds)"
    echo "exit_code: $code"
    echo "error: ${ERROR_MSG:-}"
    echo "last_step: ${LAST_STEP:-}"
    echo "last_cmd: $(mask_secrets "${LAST_CMD:-}")"
    echo "bash_lineno: ${BASH_LINENO[*]:-}"
    echo "funcname: ${FUNCNAME[*]:-}"
    echo "script_version: $SCRIPT_VERSION"
    echo "pid: $$"
    echo "pwd: $(pwd)"
    echo "wp_root: ${WP_ROOT:-}"
    echo "wp_config_path: ${WP_CONFIG_PATH:-}"
    echo "wp_home: ${WP_HOME:-}"
    echo "site_id: ${SITE_ID:-}"
    echo "mode: ${MODE:-}"
    echo "destination: ${DESTINATION:-}"
    echo "backup_root: ${BACKUP_ROOT:-}"
    echo "run_path: ${RUN_PATH:-}"
    echo "run_id: ${RUN_ID:-}"
    echo "db_name: ${DB_NAME:-}"
    echo "db_user: ${DB_USER:-}"
    echo "db_host: ${DB_HOST:-}${DB_PORT:+:$DB_PORT}"
    echo "hot_months: ${HOT_MONTHS:-}"
    echo "hot_resolved: ${HOT_REL_DIRS[*]:-}"
    echo "cold_resolved: ${COLD_REL_DIRS[*]:-}"
    echo "changed_hours: ${CHANGED_HOURS:-}"
    echo "dry_run: ${DRY_RUN:-}"
    echo "upload_only: ${UPLOAD_ONLY:-}"
    echo "upload_config: ${UPLOAD_CONFIG:-}"
    echo "artifacts: ${ARTIFACTS[*]:-}"
    echo "upload_pbs: ${UPLOAD_PBS_STATUS:-} ${UPLOAD_PBS_ERROR:-}"
    echo "upload_s3: ${UPLOAD_S3_STATUS:-} ${UPLOAD_S3_ERROR:-}"
    if [[ -n "${RUN_PATH:-}" && -d "${RUN_PATH:-}" ]]; then
      echo "--- run dir listing ---"
      ls -la "$RUN_PATH" 2>&1 || true
      echo "--- disk ---"
      df -h "$RUN_PATH" 2>&1 || true
    fi
    echo "--- commands present ---"
    for c in mysqldump tar gzip find aws rclone proxmox-backup-client php perl; do
      if command -v "$c" >/dev/null 2>&1; then
        echo "  $c: $(command -v "$c")"
      else
        echo "  $c: MISSING"
      fi
    done
    echo "==================================="
  } | while IFS= read -r line || [[ -n "$line" ]]; do
    log "$line"
  done
}

on_err() {
  local ec=$?
  local line="${1:-?}"
  # Ignore errors in cleanup paths when already dying
  [[ "${STATUS:-}" == "failed" ]] && return 0
  ERROR_MSG="${ERROR_MSG:-unhandled error at line $line (exit $ec)}"
  STATUS="failed"
  log "ERROR: unhandled failure at line $line (exit $ec), last_step=${LAST_STEP:-none}"
  if [[ "$DEBUG" -eq 1 ]]; then
    dump_debug_context "$ec"
  else
    log "Hint: re-run with --debug for xtrace and full context (also writes debug.log in run dir)"
  fi
  if [[ -n "${RUN_PATH:-}" && -d "${RUN_PATH:-}" ]]; then
    write_manifest || true
  fi
  exit "$ec"
}

enable_debug() {
  DEBUG=1
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
  log "Debug mode ON (verbose + xtrace; secrets masked in context dump)"
}

start_xtrace() {
  [[ "$DEBUG" -eq 1 ]] || return 0
  if [[ -n "${RUN_PATH:-}" && -d "${RUN_PATH:-}" ]]; then
    DEBUG_FILE="$RUN_PATH/debug.log"
    : >>"$DEBUG_FILE"
    exec {XTRACE_FD}>>"$DEBUG_FILE"
    export BASH_XTRACEFD=$XTRACE_FD
    log_debug "xtrace -> $DEBUG_FILE"
  fi
  set -x
}

stop_xtrace_sensitive() {
  # Call before writing secrets to files so they don't appear in xtrace
  [[ "$DEBUG" -eq 1 ]] || return 0
  set +x
}

resume_xtrace() {
  [[ "$DEBUG" -eq 1 ]] || return 0
  set -x
}

die() {
  local code="$1"; shift
  ERROR_MSG="$*"
  STATUS="failed"
  set +x 2>/dev/null || true
  log "ERROR($code): $*"
  if [[ "$DEBUG" -eq 1 ]]; then
    dump_debug_context "$code"
  else
    log "Hint: re-run with --debug (or DEBUG=1) for detailed diagnostics"
    [[ -n "${LAST_STEP:-}" ]] && log "Last step: $LAST_STEP"
    [[ -n "${LAST_CMD:-}" ]] && log "Last cmd: $(mask_secrets "$LAST_CMD")"
  fi
  if [[ -n "${RUN_PATH:-}" && -d "${RUN_PATH:-}" ]]; then
    write_manifest || true
    [[ -n "${DEBUG_FILE:-}" ]] && log "Debug log: $DEBUG_FILE"
    [[ -n "${LOG_FILE:-}" ]] && log "Backup log: $LOG_FILE"
  fi
  exit "$code"
}

abs_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$p"
  else
    readlink -f "$p" 2>/dev/null || {
      local dir base
      dir="$(cd "$(dirname "$p")" && pwd)"
      base="$(basename "$p")"
      printf '%s/%s\n' "$dir" "$base"
    }
  fi
}

json_escape() {
  local s="${1:-}"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wp-root) WP_ROOT="${2:-}"; shift 2 ;;
      --wp-config) WP_CONFIG_EXPLICIT="${2:-}"; shift 2 ;;
      --backup-root) BACKUP_ROOT="${2:-}"; shift 2 ;;
      --site-id) SITE_ID="${2:-}"; shift 2 ;;
      --mode) MODE="${2:-}"; shift 2 ;;
      --hot-months) HOT_MONTHS="${2:-}"; shift 2 ;;
      --hot-days) die "$E_ARGS" "--hot-days was removed; use --hot-months N (calendar months)" ;;
      --month-names) MONTH_NAMES_FILE="${2:-}"; shift 2 ;;
      --changed-hours) CHANGED_HOURS="${2:-}"; shift 2 ;;
      --destination) DESTINATION="${2:-}"; shift 2 ;;
      --upload-config) UPLOAD_CONFIG="${2:-}"; shift 2 ;;
      --skip-upload) SKIP_UPLOAD=1; shift ;;
      --keep-local)
        KEEP_LOCAL="${2:-}"
        shift 2
        ;;
      --keep-runs) KEEP_RUNS="${2:-}"; shift 2 ;;
      --keep-changed-runs) KEEP_CHANGED_RUNS="${2:-}"; shift 2 ;;
      --min-free-gb) MIN_FREE_GB="${2:-}"; shift 2 ;;
      --exclude-from) EXCLUDE_FROM="${2:-}"; shift 2 ;;
      --allow-php-parse) ALLOW_PHP_PARSE=1; shift ;;
      --upload-only) UPLOAD_ONLY=1; shift ;;
      --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --debug) DEBUG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "$E_ARGS" "Unknown argument: $1" ;;
    esac
  done

  if [[ "${DEBUG:-0}" == "1" || "${DEBUG:-}" == "true" || "${DEBUG:-}" == "yes" ]]; then
    DEBUG=1
  else
    DEBUG=0
  fi

  if [[ "$SKIP_UPLOAD" -eq 1 ]]; then
    DESTINATION="local"
  fi

  case "$DESTINATION" in
    local|pbs|s3|both) ;;
    *) die "$E_ARGS" "Invalid --destination: $DESTINATION (local|pbs|s3|both)" ;;
  esac

  case "$KEEP_LOCAL" in
    yes|no) ;;
    *) die "$E_ARGS" "Invalid --keep-local: $KEEP_LOCAL (yes|no)" ;;
  esac

  if [[ "$UPLOAD_ONLY" -eq 1 ]]; then
    [[ -n "$RUN_DIR" ]] || die "$E_ARGS" "--upload-only requires --run-dir"
    [[ -d "$RUN_DIR" ]] || die "$E_ARGS" "Run dir not found: $RUN_DIR"
    RUN_DIR="$(abs_path "$RUN_DIR")"
    return 0
  fi

  [[ -n "$WP_ROOT" ]] || die "$E_ARGS" "--wp-root is required"
  [[ "$WP_ROOT" = /* ]] || die "$E_ARGS" "--wp-root must be an absolute path"
  [[ -d "$WP_ROOT" ]] || die "$E_ARGS" "wp-root is not a directory: $WP_ROOT"
  WP_ROOT="$(abs_path "$WP_ROOT")"

  case "$MODE" in
    full|db|site|uploads-hot|uploads-cold|uploads-changed|uploads-all) ;;
    *) die "$E_ARGS" "Invalid --mode: $MODE" ;;
  esac

  [[ "$HOT_MONTHS" =~ ^[0-9]+$ ]] || die "$E_ARGS" "--hot-months must be integer"
  if [[ -n "$MONTH_NAMES_FILE" && ! -f "$MONTH_NAMES_FILE" ]]; then
    die "$E_ARGS" "month-names file not found: $MONTH_NAMES_FILE"
  fi
  [[ "$CHANGED_HOURS" =~ ^[0-9]+$ ]] || die "$E_ARGS" "--changed-hours must be integer"
  [[ "$KEEP_RUNS" =~ ^[0-9]+$ ]] || die "$E_ARGS" "--keep-runs must be integer"
  [[ "$KEEP_CHANGED_RUNS" =~ ^[0-9]+$ ]] || die "$E_ARGS" "--keep-changed-runs must be integer"
  [[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || die "$E_ARGS" "--min-free-gb must be integer"

  if [[ -z "$SITE_ID" ]]; then
    SITE_ID="$(basename "$WP_ROOT")"
  fi
}

load_upload_config() {
  if [[ -n "$UPLOAD_CONFIG" ]]; then
    [[ -f "$UPLOAD_CONFIG" ]] || die "$E_ARGS" "Upload config not found: $UPLOAD_CONFIG"
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$UPLOAD_CONFIG"
    set +a
  fi

  if [[ -n "${DESTINATION:-}" && -n "${DESTINATION_FROM_FILE:-}" ]]; then
    :
  fi
  # Optional DESTINATION override from config only if CLI left default and config set it —
  # CLI already parsed; config may set PBS_/S3_ and UPLOAD_ORDER.
  if [[ -n "${UPLOAD_ORDER:-}" ]]; then
    case "$UPLOAD_ORDER" in
      PBS_THEN_S3|S3_THEN_PBS) ;;
      *) die "$E_ARGS" "UPLOAD_ORDER must be PBS_THEN_S3 or S3_THEN_PBS" ;;
    esac
  fi

  if [[ "$DESTINATION" == "local" ]]; then
    return 0
  fi

  need_pbs=0
  need_s3=0
  case "$DESTINATION" in
    pbs) need_pbs=1 ;;
    s3) need_s3=1 ;;
    both) need_pbs=1; need_s3=1 ;;
  esac

  if [[ "$need_pbs" -eq 1 ]]; then
    [[ -n "${PBS_REPOSITORY:-}" ]] || die "$E_ARGS" "PBS_REPOSITORY required for destination=$DESTINATION"
    if [[ -z "${PBS_PASSWORD:-}" && -n "${PBS_PASSWORD_FILE:-}" ]]; then
      [[ -f "$PBS_PASSWORD_FILE" ]] || die "$E_ARGS" "PBS_PASSWORD_FILE not found"
      PBS_PASSWORD="$(<"$PBS_PASSWORD_FILE")"
      export PBS_PASSWORD
    fi
    [[ -n "${PBS_PASSWORD:-}" || -n "${PBS_API_TOKEN:-}" ]] || \
      die "$E_ARGS" "PBS_PASSWORD, PBS_PASSWORD_FILE or PBS_API_TOKEN required"
    command -v proxmox-backup-client >/dev/null 2>&1 || \
      die "$E_ARGS" "proxmox-backup-client not found in PATH"
  fi

  if [[ "$need_s3" -eq 1 ]]; then
    [[ -n "${S3_BUCKET:-}" ]] || die "$E_ARGS" "S3_BUCKET required for destination=$DESTINATION"
    if ! command -v aws >/dev/null 2>&1 && ! command -v rclone >/dev/null 2>&1; then
      die "$E_ARGS" "Need aws CLI or rclone for S3 destination"
    fi
  fi
}

find_wp_config() {
  if [[ -n "$WP_CONFIG_EXPLICIT" ]]; then
    [[ -f "$WP_CONFIG_EXPLICIT" ]] || die "$E_ARGS" "wp-config not found: $WP_CONFIG_EXPLICIT"
    WP_CONFIG_PATH="$(abs_path "$WP_CONFIG_EXPLICIT")"
    WP_HOME="$(dirname "$WP_CONFIG_PATH")"
    return 0
  fi

  local -a found=()
  local candidate
  if [[ -f "$WP_ROOT/wp-config.php" ]]; then
    found+=("$WP_ROOT/wp-config.php")
  fi

  # Depth 0 is handled above. TZ allows wp-root/a/b/c/wp-config.php (3 dirs)
  # and rejects wp-root/a/b/c/d/wp-config.php. find counts the file itself,
  # so the file at three directories is maxdepth 4.
  while IFS= read -r -d '' candidate; do
    # Stay inside WP_ROOT (no escape via symlink outside)
    local real
    real="$(abs_path "$candidate")"
    case "$real" in
      "$WP_ROOT"/*) found+=("$real") ;;
      *) log "Skipping wp-config outside wp-root: $real" ;;
    esac
  done < <(find "$WP_ROOT" -mindepth 1 -maxdepth 4 -type f -name 'wp-config.php' -print0 2>/dev/null || true)

  # Deduplicate
  local -A seen=()
  local -a uniq=()
  local f
  for f in "${found[@]+"${found[@]}"}"; do
    if [[ -z "${seen[$f]:-}" ]]; then
      seen[$f]=1
      uniq+=("$f")
    fi
  done

  if [[ ${#uniq[@]} -eq 0 ]]; then
    die "$E_ARGS" "wp-config.php not found under $WP_ROOT (allowed: the root or up to 3 directories below it)"
  fi
  if [[ ${#uniq[@]} -gt 1 ]]; then
    log "Multiple wp-config.php found:"
    for f in "${uniq[@]}"; do log "  - $f"; done
    die "$E_ARGS" "Multiple wp-config.php found; pass --wp-config FILE"
  fi

  WP_CONFIG_PATH="${uniq[0]}"
  WP_HOME="$(dirname "$WP_CONFIG_PATH")"
  log "Using wp-config: $WP_CONFIG_PATH"
  log "wp_home: $WP_HOME"
}

extract_define() {
  local key="$1"
  local file="$2"
  local val=""
  if command -v perl >/dev/null 2>&1; then
    val="$(perl -ne "if (!/^\\s*\\/\\// && /define\\s*\\(\\s*['\\\"]${key}['\\\"]\\s*,\\s*['\\\"]([^'\\\"]*)['\\\"]\\s*\\)/) { print \$1; exit }" "$file" 2>/dev/null || true)"
  fi
  if [[ -z "$val" ]]; then
    val="$(grep -E "define\s*\(\s*['\"]${key}['\"]" "$file" | grep -v '^\s*//' | head -n1 \
      | sed -E "s/.*define[[:space:]]*\([[:space:]]*['\"]${key}['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\1/" || true)"
  fi
  # sed leaves whole line if no match — detect that
  if [[ -z "$val" || "$val" == *"define("* ]]; then
    return 1
  fi
  printf '%s' "$val"
}

parse_wp_config_text() {
  local file="$1"
  DB_NAME="$(extract_define DB_NAME "$file")" || return 1
  DB_USER="$(extract_define DB_USER "$file")" || return 1
  DB_PASSWORD="$(extract_define DB_PASSWORD "$file")" || return 1
  DB_HOST_RAW="$(extract_define DB_HOST "$file")" || return 1
  return 0
}

parse_wp_config_php() {
  local file="$1"
  local out
  out="$(php -r '
    $c = file_get_contents($argv[1]);
    if (!preg_match("/define\s*\(\s*[\"'\'']DB_NAME[\"'\'']\s*,\s*[\"'\''](.*)[\"'\'']\s*\)/", $c, $m)) exit(1);
    echo $m[1], "\n";
    if (!preg_match("/define\s*\(\s*[\"'\'']DB_USER[\"'\'']\s*,\s*[\"'\''](.*)[\"'\'']\s*\)/", $c, $m)) exit(1);
    echo $m[1], "\n";
    if (!preg_match("/define\s*\(\s*[\"'\'']DB_PASSWORD[\"'\'']\s*,\s*[\"'\''](.*)[\"'\'']\s*\)/", $c, $m)) exit(1);
    echo $m[1], "\n";
    if (!preg_match("/define\s*\(\s*[\"'\'']DB_HOST[\"'\'']\s*,\s*[\"'\''](.*)[\"'\'']\s*\)/", $c, $m)) exit(1);
    echo $m[1], "\n";
  ' "$file")" || return 1
  mapfile -t _dbvals <<<"$out"
  DB_NAME="${_dbvals[0]}"
  DB_USER="${_dbvals[1]}"
  DB_PASSWORD="${_dbvals[2]}"
  DB_HOST_RAW="${_dbvals[3]}"
}

parse_db_host() {
  DB_HOST="$DB_HOST_RAW"
  DB_PORT=""
  if [[ "$DB_HOST_RAW" == *:* ]]; then
    # host:port — but avoid IPv6; simple split on last colon if numeric port
    local maybe_port="${DB_HOST_RAW##*:}"
    if [[ "$maybe_port" =~ ^[0-9]+$ ]]; then
      DB_HOST="${DB_HOST_RAW%:*}"
      DB_PORT="$maybe_port"
    fi
  fi
}

load_db_settings() {
  if parse_wp_config_text "$WP_CONFIG_PATH"; then
    :
  elif [[ "$ALLOW_PHP_PARSE" -eq 1 ]]; then
    log "Text parse failed; trying --allow-php-parse"
    parse_wp_config_php "$WP_CONFIG_PATH" || die "$E_DB_CONST" "Failed to parse DB_* from wp-config.php"
  else
    die "$E_DB_CONST" "Failed to parse DB_* from wp-config.php (try --allow-php-parse)"
  fi
  parse_db_host
  log "DB_NAME=$DB_NAME DB_USER=$DB_USER DB_HOST=$DB_HOST${DB_PORT:+:$DB_PORT} DB_PASSWORD=***"
}

check_free_space() {
  local target="$1"
  mkdir -p "$target"
  local avail_kb
  avail_kb="$(df -Pk "$target" | awk 'NR==2{print $4}')"
  local need_kb=$((MIN_FREE_GB * 1024 * 1024))
  if [[ "$avail_kb" -lt "$need_kb" ]]; then
    die "$E_SPACE" "Not enough free space under $target (need >= ${MIN_FREE_GB}GiB)"
  fi
}

prepare_run_dir() {
  STARTED_AT="$(date -Iseconds)"
  RUN_ID="$(date '+%Y-%m-%d_%H%M%S')"
  # Avoid collision when two runs start in the same second
  if [[ -e "$BACKUP_ROOT/$SITE_ID/$RUN_ID" ]]; then
    RUN_ID="${RUN_ID}_$$"
  fi
  RUN_PATH="$(abs_path "$BACKUP_ROOT/$SITE_ID/$RUN_ID")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN would create: $RUN_PATH"
    LOG_FILE=""
    return 0
  fi
  mkdir -p "$BACKUP_ROOT/$SITE_ID"
  if [[ -e "$RUN_PATH" ]]; then
    RUN_ID="${RUN_ID}_$$"
    RUN_PATH="$(abs_path "$BACKUP_ROOT/$SITE_ID/$RUN_ID")"
  fi
  mkdir -p "$RUN_PATH"
  LOG_FILE="$RUN_PATH/backup.log"
  MANIFEST_FILE="$RUN_PATH/manifest.json"
  : >"$LOG_FILE"
  log "Run directory: $RUN_PATH"
  if [[ "$DEBUG" -eq 1 ]]; then
    DEBUG_FILE="$RUN_PATH/debug.log"
    : >"$DEBUG_FILE"
    log "Debug log: $DEBUG_FILE"
    start_xtrace
  fi
}

rel_to_root() {
  local path="$1"
  if [[ "$path" == "$WP_ROOT" ]]; then
    printf '.'
    return
  fi
  printf '%s\n' "${path#"$WP_ROOT"/}"
}

load_month_names() {
  MONTH_NUM=()
  local i n
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    n=$((10#$i))
    MONTH_NUM["$i"]=$n
  done
  [[ -n "$MONTH_NAMES_FILE" ]] || return 0
  local name num rest line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    # trim
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    read -r name num rest <<<"$line"
    [[ -n "${rest:-}" ]] && die "$E_ARGS" "Bad month-names line (use: NAME NUMBER): $line"
    [[ "$num" =~ ^[0-9]+$ ]] || die "$E_ARGS" "Month number must be 1-12: $line"
    (( 10#$num >= 1 && 10#$num <= 12 )) || die "$E_ARGS" "Month number must be 1-12: $line"
    MONTH_NUM["$name"]=$((10#$num))
  done <"$MONTH_NAMES_FILE"
}

compute_hot_window() {
  HOT_YEAR_MONTH=()
  local ref="${WP_BACKUP_REFERENCE_DATE:-}"
  local y m i key
  if [[ -n "$ref" ]]; then
    [[ "$ref" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "$E_ARGS" "WP_BACKUP_REFERENCE_DATE must be YYYY-MM-DD"
    y=$((10#${ref:0:4}))
    m=$((10#${ref:5:2}))
    (( m >= 1 && m <= 12 )) || die "$E_ARGS" "WP_BACKUP_REFERENCE_DATE has invalid month"
  else
    y=$((10#$(date +%Y)))
    m=$((10#$(date +%m)))
  fi
  for ((i = 0; i < HOT_MONTHS; i++)); do
    printf -v key '%04d-%02d' "$y" "$m"
    HOT_YEAR_MONTH["$key"]=1
    m=$((m - 1))
    if (( m < 1 )); then
      m=12
      y=$((y - 1))
    fi
  done
  if [[ "$DEBUG" -eq 1 ]]; then
    local k joined=""
    for k in "${!HOT_YEAR_MONTH[@]}"; do
      joined+="$k "
    done
    log_debug "hot window: ${joined:-none}"
  fi
}

classify_upload_months() {
  HOT_REL_DIRS=()
  COLD_REL_DIRS=()
  local uploads="$WP_HOME/wp-content/uploads"
  if [[ ! -d "$uploads" ]]; then
    NOTES="uploads directory missing; hot/cold artifacts skipped"
    log "$NOTES"
    return 0
  fi
  local uploads_real year_path year month_path month num key rel year_real month_real
  uploads_real="$(abs_path "$uploads")"
  while IFS= read -r -d '' year_path; do
    year="$(basename "$year_path")"
    [[ "$year" =~ ^[0-9]{4}$ ]] || continue
    year_real="$(abs_path "$year_path")"
    case "$year_real" in
      "$uploads_real"/*) ;;
      *) log "Skipping year dir outside uploads: $year_real"; continue ;;
    esac
    while IFS= read -r -d '' month_path; do
      month="$(basename "$month_path")"
      [[ -n "${MONTH_NUM[$month]+x}" ]] || continue
      month_real="$(abs_path "$month_path")"
      case "$month_real" in
        "$uploads_real"/*) ;;
        *) log "Skipping month dir outside uploads: $month_real"; continue ;;
      esac
      num="${MONTH_NUM[$month]}"
      printf -v key '%04d-%02d' "$((10#$year))" "$num"
      rel="$year/$month"
      if [[ -n "${HOT_YEAR_MONTH[$key]:-}" ]]; then
        HOT_REL_DIRS+=("$rel")
      else
        COLD_REL_DIRS+=("$rel")
      fi
    done < <(find "$year_path" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  done < <(find "$uploads" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  log "uploads-hot months: ${HOT_REL_DIRS[*]:-(none)}"
  log "uploads-cold months: ${COLD_REL_DIRS[*]:-(none)}"
}

prepare_upload_classes() {
  load_month_names
  compute_hot_window
  classify_upload_months
}

json_string_array() {
  local first=1 item out="["
  for item in "$@"; do
    if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
    out+="\"$(json_escape "$item")\""
  done
  out+="]"
  printf '%s' "$out"
}

make_empty_tar() {
  local out="$1"
  tar --numeric-owner -czf "$out" --files-from /dev/null
}

home_rel_prefix() {
  if [[ "$WP_HOME" == "$WP_ROOT" ]]; then
    printf ''
  else
    printf '%s/' "$(rel_to_root "$WP_HOME")"
  fi
}

backup_db() {
  step "backup database ($DB_NAME)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: mysqldump $DB_NAME -> db.sql.gz"
    return 0
  fi
  local cnf out rc=0
  cnf="$(mktemp)"
  out="$RUN_PATH/db.sql.gz"
  chmod 600 "$cnf"
  stop_xtrace_sensitive
  {
    echo "[client]"
    echo "user=$DB_USER"
    echo "password=$DB_PASSWORD"
    echo "host=$DB_HOST"
    [[ -n "$DB_PORT" ]] && echo "port=$DB_PORT"
  } >"$cnf"
  resume_xtrace
  # shellcheck disable=SC2064
  trap 'rm -f "$cnf"' RETURN

  LAST_CMD="mysqldump --defaults-extra-file=<tmp> --skip-column-statistics --single-transaction --skip-lock-tables --no-tablespaces --quick --routines --events --triggers --databases $DB_NAME | gzip"
  log_debug "mysqldump host=$DB_HOST port=${DB_PORT:-default} user=$DB_USER db=$DB_NAME"
  set +e
  mysqldump --defaults-extra-file="$cnf" \
      --skip-column-statistics \
      --single-transaction \
      --skip-lock-tables \
      --no-tablespaces \
      --quick --routines --events --triggers \
      --databases "$DB_NAME" 2>"$RUN_PATH/mysqldump.err" | gzip -c >"$out"
  rc=${PIPESTATUS[0]}
  set -e
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$out"
    if [[ -s "$RUN_PATH/mysqldump.err" ]]; then
      log "mysqldump stderr:"
      sed 's/password[^ ]*/password ***/gi' "$RUN_PATH/mysqldump.err" | while IFS= read -r line; do log "  $line"; done
    fi
    die "$E_DUMP" "mysqldump failed (exit $rc); see mysqldump.err / --debug"
  fi
  rm -f "$cnf" "$RUN_PATH/mysqldump.err"
  trap - RETURN
  ARTIFACTS+=("db.sql.gz")
  log "Created db.sql.gz ($(du -h "$out" | awk '{print $1}'))"
}

backup_site() {
  step "backup site files (exclude YYYY/MM uploads and cache)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: tar site -> site.tar.gz (month dirs excluded: ${HOT_REL_DIRS[*]:-} ${COLD_REL_DIRS[*]:-})"
    return 0
  fi
  local out="$RUN_PATH/site.tar.gz" rc=0 prefix exclude_file d
  prefix="$(home_rel_prefix)"
  exclude_file="$(mktemp)"
  {
    echo ".git"
    echo "*/.git"
    echo "${prefix}wp-content/cache"
    echo "${prefix}wp-content/upgrade"
    echo "${prefix}wp-content/tmp"
    echo "${prefix}wp-content/temp"
    echo "${prefix}wp-content/w3tc-cache"
    echo "${prefix}wp-content/wflogs"
    echo "${prefix}wp-content/wp-rocket-config"
    echo "${prefix}wp-content/cache-*"
    for d in "${HOT_REL_DIRS[@]+"${HOT_REL_DIRS[@]}"}" "${COLD_REL_DIRS[@]+"${COLD_REL_DIRS[@]}"}"; do
      [[ -n "$d" ]] && echo "${prefix}wp-content/uploads/${d}"
    done
    if [[ -n "$EXCLUDE_FROM" ]]; then
      [[ -f "$EXCLUDE_FROM" ]] || die "$E_ARGS" "exclude-from not found: $EXCLUDE_FROM"
      cat "$EXCLUDE_FROM"
    fi
  } >"$exclude_file"

  log_debug "site exclude file: $exclude_file"
  LAST_CMD="tar -C $WP_ROOT --exclude-from=<tmp> -czf site.tar.gz ."
  set +e
  tar -C "$WP_ROOT" --numeric-owner --exclude-from="$exclude_file" -czf "$out" . 2>"$RUN_PATH/site-tar.err"
  rc=$?
  set -e
  rm -f "$exclude_file"
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$out"
    [[ -s "$RUN_PATH/site-tar.err" ]] && log "tar stderr:" && sed 's/^/  /' "$RUN_PATH/site-tar.err" | while IFS= read -r line; do log "$line"; done
    die "$E_SITE" "site tar failed (exit $rc)"
  fi
  rm -f "$RUN_PATH/site-tar.err"
  ARTIFACTS+=("site.tar.gz")
  log "Created site.tar.gz ($(du -h "$out" | awk '{print $1}'))"
}

archive_month_trees() {
  local label="$1"
  local out_name="$2"
  shift 2
  local -a dirs=("$@")

  step "backup uploads-$label"
  local uploads="$WP_HOME/wp-content/uploads"
  local out="$RUN_PATH/$out_name"

  if [[ ! -d "$uploads" ]]; then
    log "uploads dir missing; skip uploads-$label"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: uploads-$label -> $out_name dirs: ${dirs[*]:-(none)}"
    return 0
  fi

  if [[ ${#dirs[@]} -eq 0 ]]; then
    log "No month directories for uploads-$label; writing empty archive"
    make_empty_tar "$out"
    ARTIFACTS+=("$out_name")
    return 0
  fi

  local has=""
  has="$(cd "$uploads" && find "${dirs[@]}" -type f -print -quit 2>/dev/null || true)"
  if [[ -z "$has" ]]; then
    log "No files in uploads-$label month dirs; writing empty archive"
    make_empty_tar "$out"
    ARTIFACTS+=("$out_name")
    return 0
  fi

  local -a runner=()
  if [[ "$label" == "cold" ]]; then
    command -v nice >/dev/null 2>&1 && runner+=(nice -n 19)
    command -v ionice >/dev/null 2>&1 && runner+=(ionice -c 3)
  fi

  log "Archiving uploads-$label (${#dirs[@]} month dirs) -> $out_name"
  LAST_CMD="find ${dirs[*]} -type f | tar -C $uploads -czf $out_name"
  local rc=0
  set +e
  (cd "$uploads" && find "${dirs[@]}" -type f -printf '%p\0') \
    | "${runner[@]}" tar -C "$uploads" --null --verbatim-files-from --numeric-owner -czf "$out" --files-from=- \
      2>"$RUN_PATH/uploads-${label}-tar.err"
  rc=${PIPESTATUS[1]}
  set -e
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$out"
    [[ -s "$RUN_PATH/uploads-${label}-tar.err" ]] && log "tar stderr:" && sed 's/^/  /' "$RUN_PATH/uploads-${label}-tar.err" | while IFS= read -r line; do log "$line"; done
    die "$E_UPLOADS" "uploads-$label tar failed (exit $rc)"
  fi
  rm -f "$RUN_PATH/uploads-${label}-tar.err"
  ARTIFACTS+=("$out_name")
  log "Created $out_name ($(du -h "$out" | awk '{print $1}'))"
}

backup_uploads_hot() {
  archive_month_trees "hot" "uploads-hot.tar.gz" "${HOT_REL_DIRS[@]+"${HOT_REL_DIRS[@]}"}"
}

backup_uploads_cold() {
  check_free_space "$BACKUP_ROOT"
  archive_month_trees "cold" "uploads-cold.tar.gz" "${COLD_REL_DIRS[@]+"${COLD_REL_DIRS[@]}"}"
}

backup_uploads_changed() {
  step "backup changed files under wp-root"
  local mins=$((CHANGED_HOURS * 60))
  local ts out_name out home_rel
  ts="$(date '+%Y%m%d-%H%M%S')"
  out_name="uploads-changed-${ts}.tar.gz"
  out="$RUN_PATH/$out_name"
  if [[ "$WP_HOME" == "$WP_ROOT" ]]; then
    home_rel="."
  else
    home_rel="./$(rel_to_root "$WP_HOME")"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: changed files under $WP_ROOT newer than ${CHANGED_HOURS}h -> $out_name"
    return 0
  fi

  local -a prune=(
    -name .git -o
    -path "${home_rel}/wp-content/cache" -o
    -path "${home_rel}/wp-content/upgrade" -o
    -path "${home_rel}/wp-content/tmp" -o
    -path "${home_rel}/wp-content/temp" -o
    -path "${home_rel}/wp-content/w3tc-cache" -o
    -path "${home_rel}/wp-content/wflogs" -o
    -path "${home_rel}/wp-content/wp-rocket-config" -o
    -path "${home_rel}/wp-content/cache-*"
  )
  case "$BACKUP_ROOT" in
    "$WP_ROOT"/*)
      prune+=(-o -path "./$(rel_to_root "$BACKUP_ROOT")")
      ;;
  esac

  log "Scanning $WP_ROOT for files changed within ${CHANGED_HOURS}h"
  LAST_CMD="find $WP_ROOT -mmin -${mins} | tar -C $WP_ROOT"
  local rc=0 has=""
  has="$(cd "$WP_ROOT" && find . \( "${prune[@]}" \) -prune -o -type f -mmin "-${mins}" -print -quit || true)"
  if [[ -z "$has" ]]; then
    log "No changed files; writing empty archive"
    make_empty_tar "$out"
    ARTIFACTS+=("$out_name")
    return 0
  fi

  set +e
  (cd "$WP_ROOT" && find . \( "${prune[@]}" \) -prune -o -type f -mmin "-${mins}" -printf '%P\0') \
    | tar -C "$WP_ROOT" --null --verbatim-files-from --numeric-owner -czf "$out" --files-from=- \
      2>"$RUN_PATH/uploads-changed-tar.err"
  rc=${PIPESTATUS[1]}
  set -e
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$out"
    [[ -s "$RUN_PATH/uploads-changed-tar.err" ]] && log "tar stderr:" && sed 's/^/  /' "$RUN_PATH/uploads-changed-tar.err" | while IFS= read -r line; do log "$line"; done
    die "$E_UPLOADS" "uploads-changed tar failed (exit $rc)"
  fi
  rm -f "$RUN_PATH/uploads-changed-tar.err"
  ARTIFACTS+=("$out_name")
  log "Created $out_name ($(du -h "$out" | awk '{print $1}'))"
}

write_manifest() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ -n "${RUN_PATH:-}" && -d "${RUN_PATH:-}" ]] || return 0
  FINISHED_AT="$(date -Iseconds)"
  MANIFEST_FILE="${MANIFEST_FILE:-$RUN_PATH/manifest.json}"

  local artifacts_json="["
  local first=1
  local a size
  for a in "${ARTIFACTS[@]+"${ARTIFACTS[@]}"}"; do
    size=0
    [[ -f "$RUN_PATH/$a" ]] && size="$(stat -c%s "$RUN_PATH/$a" 2>/dev/null || stat -f%z "$RUN_PATH/$a" 2>/dev/null || echo 0)"
    if [[ $first -eq 1 ]]; then first=0; else artifacts_json+=","; fi
    artifacts_json+="{\"name\":\"$(json_escape "$a")\",\"bytes\":$size}"
  done
  artifacts_json+="]"

  cat >"$MANIFEST_FILE" <<EOF
{
  "script_version": "$(json_escape "$SCRIPT_VERSION")",
  "hostname": "$(json_escape "$(hostname)")",
  "site_id": "$(json_escape "$SITE_ID")",
  "wp_root": "$(json_escape "$WP_ROOT")",
  "wp_config_path": "$(json_escape "$WP_CONFIG_PATH")",
  "wp_home": "$(json_escape "$WP_HOME")",
  "run_id": "$(json_escape "$RUN_ID")",
  "run_path": "$(json_escape "$RUN_PATH")",
  "started_at": "$(json_escape "$STARTED_AT")",
  "finished_at": "$(json_escape "$FINISHED_AT")",
  "mode": "$(json_escape "$MODE")",
  "destination": "$(json_escape "$DESTINATION")",
  "status": "$(json_escape "$STATUS")",
  "db_name": "$(json_escape "$DB_NAME")",
  "hot_months": $HOT_MONTHS,
  "hot_months_resolved": $(json_string_array "${HOT_REL_DIRS[@]+"${HOT_REL_DIRS[@]}"}"),
  "changed_hours": $CHANGED_HOURS,
  "notes": "$(json_escape "$NOTES")",
  "error": "$(json_escape "$ERROR_MSG")",
  "artifacts": $artifacts_json,
  "upload": {
    "pbs": {
      "status": "$(json_escape "$UPLOAD_PBS_STATUS")",
      "finished_at": "$(json_escape "$UPLOAD_PBS_FINISHED")",
      "remote_id": "$(json_escape "$UPLOAD_PBS_REMOTE")",
      "error": "$(json_escape "$UPLOAD_PBS_ERROR")"
    },
    "s3": {
      "status": "$(json_escape "$UPLOAD_S3_STATUS")",
      "finished_at": "$(json_escape "$UPLOAD_S3_FINISHED")",
      "bucket": "$(json_escape "$UPLOAD_S3_BUCKET")",
      "key_prefix": "$(json_escape "$UPLOAD_S3_PREFIX")",
      "error": "$(json_escape "$UPLOAD_S3_ERROR")"
    }
  }
}
EOF
}

update_latest_symlink() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ "$MODE" == "full" ]] || return 0
  local link="$BACKUP_ROOT/$SITE_ID/latest"
  ln -sfn "$RUN_PATH" "$link"
  log "Updated latest -> $RUN_ID"
}

manifest_mode_of() {
  local dir="$1"
  local mode=""
  if [[ -f "$dir/manifest.json" ]]; then
    mode="$(sed -n 's/^[[:space:]]*"mode": "\([^"]*\)".*/\1/p' "$dir/manifest.json" | head -n1)"
  fi
  printf '%s' "$mode"
}

rotate_runs() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  local site_dir="$BACKUP_ROOT/$SITE_ID"
  [[ -d "$site_dir" ]] || return 0

  local want_changed=0 keep="$KEEP_RUNS"
  if [[ "$MODE" == "uploads-changed" ]]; then
    want_changed=1
    keep="$KEEP_CHANGED_RUNS"
  elif [[ "$MODE" != "full" ]]; then
    return 0
  fi

  mapfile -t runs < <(find "$site_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_' | sort -r)
  local i=0 r mode is_changed
  for r in "${runs[@]+"${runs[@]}"}"; do
    [[ "$r" == "$RUN_ID" ]] && continue
    mode="$(manifest_mode_of "$site_dir/$r")"
    is_changed=0
    [[ "$mode" == "uploads-changed" ]] && is_changed=1
    if [[ "$want_changed" -eq 1 && "$is_changed" -ne 1 ]]; then
      continue
    fi
    if [[ "$want_changed" -eq 0 && "$is_changed" -eq 1 ]]; then
      continue
    fi
    i=$((i + 1))
    # keep includes the current run, so older matching runs start at 1
    if [[ $((i + 1)) -gt $keep ]]; then
      log "Rotation: removing $site_dir/$r"
      rm -rf "$site_dir/$r"
    fi
  done
}

upload_pbs() {
  local dir="$1" rc=0
  step "upload to PBS"
  UPLOAD_PBS_STATUS="running"
  log "Uploading to PBS..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: proxmox-backup-client backup from $dir"
    UPLOAD_PBS_STATUS="success"
    UPLOAD_PBS_FINISHED="$(date -Iseconds)"
    UPLOAD_PBS_REMOTE="dry-run"
    return 0
  fi

  local bid="${PBS_BACKUP_ID:-$SITE_ID}"
  local ns_args=()
  [[ -n "${PBS_NAMESPACE:-}" ]] && ns_args+=(--ns "$PBS_NAMESPACE")
  [[ -n "${PBS_FINGERPRINT:-}" ]] && export PBS_FINGERPRINT

  if [[ -n "${PBS_API_TOKEN:-}" ]]; then
    export PBS_PASSWORD="$PBS_API_TOKEN"
  fi

  local archive_name="wp-backup.pxar"
  LAST_CMD="proxmox-backup-client backup ${archive_name}:${dir} --repository $PBS_REPOSITORY --backup-id $bid"
  log_debug "PBS_REPOSITORY=$PBS_REPOSITORY backup-id=$bid ns=${PBS_NAMESPACE:-}"
  set +e
  proxmox-backup-client backup "${archive_name}:${dir}" \
      --repository "$PBS_REPOSITORY" \
      --backup-type host \
      --backup-id "$bid" \
      "${ns_args[@]+"${ns_args[@]}"}" \
      >"$RUN_PATH/pbs-upload.out" 2>"$RUN_PATH/pbs-upload.err"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    UPLOAD_PBS_STATUS="success"
    UPLOAD_PBS_REMOTE="${PBS_REPOSITORY}/${bid}"
    UPLOAD_PBS_FINISHED="$(date -Iseconds)"
    UPLOAD_PBS_ERROR=""
    log "PBS upload OK ($UPLOAD_PBS_REMOTE)"
    rm -f "$RUN_PATH/pbs-upload.out" "$RUN_PATH/pbs-upload.err"
    return 0
  fi

  UPLOAD_PBS_STATUS="failed"
  UPLOAD_PBS_ERROR="proxmox-backup-client failed (exit $rc)"
  UPLOAD_PBS_FINISHED="$(date -Iseconds)"
  log "PBS upload FAILED (exit $rc)"
  [[ -s "$RUN_PATH/pbs-upload.err" ]] && log "PBS stderr:" && sed 's/password[^ ]*/***/gi;s/token[^ ]*/***/gi' "$RUN_PATH/pbs-upload.err" | while IFS= read -r line; do log "  $line"; done
  return 1
}

upload_s3() {
  local dir="$1" rc=0
  step "upload to S3"
  UPLOAD_S3_STATUS="running"
  UPLOAD_S3_BUCKET="${S3_BUCKET:-}"
  local prefix="${S3_PREFIX:-}"
  local key="${SITE_ID}/${RUN_ID}"
  [[ -n "$prefix" ]] && key="${prefix%/}/$key"
  UPLOAD_S3_PREFIX="$key"

  log "Uploading to S3 s3://${S3_BUCKET}/${key}/ ..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    UPLOAD_S3_STATUS="success"
    UPLOAD_S3_FINISHED="$(date -Iseconds)"
    return 0
  fi

  local dest="s3://${S3_BUCKET}/${key}/"
  local ok=0

  if command -v aws >/dev/null 2>&1; then
    local aws_args=(s3 sync "$dir" "$dest")
    [[ -n "${S3_ENDPOINT:-}" ]] && aws_args=(--endpoint-url "$S3_ENDPOINT" "${aws_args[@]}")
    [[ -n "${S3_REGION:-}" ]] && export AWS_DEFAULT_REGION="$S3_REGION"
    LAST_CMD="aws ${aws_args[*]}"
    log_debug "aws sync -> $dest endpoint=${S3_ENDPOINT:-default} region=${S3_REGION:-}"
    set +e
    aws "${aws_args[@]}" >"$RUN_PATH/s3-upload.out" 2>"$RUN_PATH/s3-upload.err"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]] && ok=1
  elif command -v rclone >/dev/null 2>&1; then
    local remote="${RCLONE_REMOTE:-s3}"
    LAST_CMD="rclone sync $dir ${remote}:${S3_BUCKET}/${key}"
    log_debug "rclone remote=$remote"
    set +e
    rclone sync "$dir" "${remote}:${S3_BUCKET}/${key}" >"$RUN_PATH/s3-upload.out" 2>"$RUN_PATH/s3-upload.err"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]] && ok=1
  else
    rc=127
    echo "aws/rclone missing" >"$RUN_PATH/s3-upload.err"
  fi

  if [[ "$ok" -eq 1 ]]; then
    UPLOAD_S3_STATUS="success"
    UPLOAD_S3_FINISHED="$(date -Iseconds)"
    UPLOAD_S3_ERROR=""
    log "S3 upload OK"
    rm -f "$RUN_PATH/s3-upload.out" "$RUN_PATH/s3-upload.err"
    return 0
  fi

  UPLOAD_S3_STATUS="failed"
  UPLOAD_S3_ERROR="S3 upload failed (exit $rc)"
  UPLOAD_S3_FINISHED="$(date -Iseconds)"
  log "S3 upload FAILED (exit $rc)"
  [[ -s "$RUN_PATH/s3-upload.err" ]] && log "S3 stderr:" && sed 's/Secret[^ ]*/***/gi;s/AKIA[A-Z0-9]*/***/g' "$RUN_PATH/s3-upload.err" | while IFS= read -r line; do log "  $line"; done
  return 1
}

do_uploads() {
  local dir="$1"
  if [[ "$DESTINATION" == "local" ]]; then
    log "Destination=local; skip remote upload"
    return 0
  fi

  local pbs_ok=1 s3_ok=1
  case "$DESTINATION" in
    pbs)
      upload_pbs "$dir" || pbs_ok=0
      ;;
    s3)
      upload_s3 "$dir" || s3_ok=0
      ;;
    both)
      if [[ "$UPLOAD_ORDER" == "S3_THEN_PBS" ]]; then
        upload_s3 "$dir" || s3_ok=0
        upload_pbs "$dir" || pbs_ok=0
      else
        upload_pbs "$dir" || pbs_ok=0
        upload_s3 "$dir" || s3_ok=0
      fi
      ;;
  esac

  write_manifest

  if [[ "$DESTINATION" == "pbs" && "$pbs_ok" -ne 1 ]]; then
    return 1
  fi
  if [[ "$DESTINATION" == "s3" && "$s3_ok" -ne 1 ]]; then
    return 1
  fi
  if [[ "$DESTINATION" == "both" && ( "$pbs_ok" -ne 1 || "$s3_ok" -ne 1 ) ]]; then
    return 1
  fi

  if [[ "$KEEP_LOCAL" == "no" && "$DRY_RUN" -eq 0 ]]; then
    log "Removing local run after successful upload (--keep-local no)"
    # remove contents but keep path reference cleared carefully
    local parent
    parent="$(dirname "$dir")"
    rm -rf "$dir"
    # fix latest if pointed here
    if [[ -L "$parent/latest" ]]; then
      local cur
      cur="$(readlink -f "$parent/latest" || true)"
      if [[ "$cur" == "$dir" ]]; then
        rm -f "$parent/latest"
      fi
    fi
  fi
  return 0
}

run_backup_modes() {
  case "$MODE" in
    full)
      backup_db
      backup_site
      backup_uploads_hot
      backup_uploads_cold
      ;;
    db) backup_db ;;
    site) backup_site ;;
    uploads-hot) backup_uploads_hot ;;
    uploads-cold) backup_uploads_cold ;;
    uploads-changed) backup_uploads_changed ;;
    uploads-all)
      backup_uploads_hot
      backup_uploads_cold
      ;;
  esac
}

main_upload_only() {
  step "upload-only init"
  load_upload_config
  RUN_PATH="$RUN_DIR"
  RUN_ID="$(basename "$RUN_PATH")"
  SITE_ID="${SITE_ID:-$(basename "$(dirname "$RUN_PATH")")}"
  LOG_FILE="$RUN_PATH/backup.log"
  MANIFEST_FILE="$RUN_PATH/manifest.json"
  STARTED_AT="$(date -Iseconds)"
  [[ -f "$LOG_FILE" ]] || : >"$LOG_FILE"
  if [[ "$DEBUG" -eq 1 ]]; then
    DEBUG_FILE="$RUN_PATH/debug.log"
    : >>"$DEBUG_FILE"
    start_xtrace
  fi
  log "Upload-only mode for $RUN_PATH destination=$DESTINATION"

  # Try to recover site_id / wp paths from existing manifest if present
  if [[ -f "$MANIFEST_FILE" ]] && command -v python3 >/dev/null 2>&1; then
    SITE_ID="$(python3 -c "import json;print(json.load(open('$MANIFEST_FILE')).get('site_id','$SITE_ID'))" 2>/dev/null || printf '%s' "$SITE_ID")"
  fi

  if ! do_uploads "$RUN_PATH"; then
    STATUS="failed"
    ERROR_MSG="remote upload failed"
    write_manifest
    [[ "$DEBUG" -eq 1 ]] && dump_debug_context "$E_REMOTE"
    exit "$E_REMOTE"
  fi
  STATUS="success"
  write_manifest
  log "Done (upload-only)"
  exit "$E_OK"
}

main() {
  parse_args "$@"
  trap 'on_err "$LINENO"' ERR

  if [[ "$DEBUG" -eq 1 ]]; then
    enable_debug
    log_debug "argv: $(mask_secrets "$*")"
  fi

  if [[ "$UPLOAD_ONLY" -eq 1 ]]; then
    main_upload_only
  fi

  step "load upload config"
  load_upload_config
  step "find wp-config"
  find_wp_config
  case "$MODE" in
    full|db)
      step "parse DB settings"
      load_db_settings
      ;;
  esac
  case "$MODE" in
    db) ;;
    *)
      step "classify uploads year/month"
      prepare_upload_classes
      ;;
  esac

  step "check free space"
  check_free_space "$BACKUP_ROOT"
  step "prepare run directory"
  prepare_run_dir

  log "Starting backup mode=$MODE destination=$DESTINATION site_id=$SITE_ID"
  log_debug "wp_root=$WP_ROOT wp_home=$WP_HOME config=$WP_CONFIG_PATH"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    run_backup_modes
    log "DRY-RUN complete"
    exit "$E_OK"
  fi

  run_backup_modes

  STATUS="success"
  write_manifest
  update_latest_symlink
  rotate_runs

  if ! do_uploads "$RUN_PATH"; then
    STATUS="failed"
    ERROR_MSG="remote upload failed (local artifacts kept)"
    write_manifest
    [[ "$DEBUG" -eq 1 ]] && dump_debug_context "$E_REMOTE"
    log "Hint: inspect $LOG_FILE${DEBUG_FILE:+ and $DEBUG_FILE}"
    exit "$E_REMOTE"
  fi

  STATUS="success"
  write_manifest
  log "Backup finished successfully"
  [[ "$DEBUG" -eq 1 ]] && log_debug "success; artifacts=${ARTIFACTS[*]:-none}"
  exit "$E_OK"
}

main "$@"
