#!/usr/bin/env bash
################################################################################
# CVR Data Pipeline Runner
#
# Orchestrates the complete CVR data import pipeline:
# 1) download - downloads CVR data files
# 2) unzip   - unzips downloaded files
# 3) import  - imports data into database
#
# Copyright (c) 2026 janich
# Repository: https://github.com/janich/cvrimporter-dk
# License: MIT (see /LICENSE)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
################################################################################

set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="CVR Data Pipeline"

# Remember original arg count so we can require at least one parameter
ORIGINAL_ARGC=$#


# Load config file
source "${SCRIPT_DIR}/cvr.conf" || {
    echo "ERROR: Failed to load configuration from ${SCRIPT_DIR}/cvr.conf"
    exit 1
}

# Source common functions
source "${SCRIPT_DIR}/lib/common.sh" || {
    echo "ERROR: Failed to load common functions from ${SCRIPT_DIR}/lib/common.sh"
    exit 1
}


# Defaults
IMPORT_METHOD="php"
DATE=""
SOURCE=""
DRY_RUN=false
VERBOSE=false
NO_OVERRIDES=false

# Skip flags (can be set via --skip-download etc or --skip=download,unzip)
SKIP_DOWNLOAD=false
SKIP_UNZIP=false
SKIP_IMPORT=false

LOG_DIR="${SCRIPT_DIR}/logs"
LOG_SUFFIX="$(date +%Y-%m)"
PIPELINE_LOG="${LOG_DIR}/pipeline-${LOG_SUFFIX}.log"


usage() {
    cat <<EOF
$SCRIPT_NAME

Usage: $(basename "$0") [options]

Options:
  --date YYYY-MM-DD or --date now  Date passed only to unzip step ("now" expands to today's date)
  --source NAME                    Forwarded to all steps
  --dry-run                        Do not actually run commands (forwarded)
  --verbose                        Enable verbose output (forwarded)
  --import-method METHOD           php (default) or mysql
  --no-overrides                   Do not apply any config overrides
  --skip-download                  Skip the download step
  --skip-unzip                     Skip the unzip step
  --skip-import                    Skip the import step
  --skip=LIST                      Comma-separated list of steps to skip (download,unzip,import)
  --help                           Show this help

Behavior:
  - download is executed WITHOUT --date
  - unzip is executed WITH --date
  - import is executed WITHOUT --date
  - forwards --source, --dry-run, --verbose to all steps
  - stops on first failure and exits with that step's exit code
EOF
}

# Parse args (simple)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --date)
            DATE="$2"
            shift 2
            ;;
        --date=*)
            DATE="${1#*=}"
            shift
            ;;
        --source)
            SOURCE="$2"
            shift 2
            ;;
        --source=*)
            SOURCE="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --quiet)
            VERBOSE=false
            shift
            ;;
        --import-method)
            IMPORT_METHOD="$2"
            shift 2
            ;;
        --import-method=*)
            IMPORT_METHOD="${1#*=}"
            shift
            ;;
        --no-overrides)
            NO_OVERRIDES=true
            shift
            ;;
        --skip-download)
            SKIP_DOWNLOAD=true
            shift
            ;;
        --skip-unzip)
            SKIP_UNZIP=true
            shift
            ;;
        --skip-import)
            SKIP_IMPORT=true
            shift
            ;;
        --skip=*)
            # comma separated list
            SKIP_LIST="${1#*=}"
            IFS=',' read -r -a _skips <<< "$SKIP_LIST"
            for s in "${_skips[@]}"; do
                case "$(echo "$s" | tr '[:upper:]' '[:lower:]')" in
                    download) SKIP_DOWNLOAD=true ;;
                    unzip) SKIP_UNZIP=true ;;
                    import) SKIP_IMPORT=true ;;
                    *) echo "Unknown skip target: $s"; usage; exit 1 ;;
                esac
            done
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Require at least one CLI parameter to run
if [[ $ORIGINAL_ARGC -eq 0 ]]; then
    echo "No parameters provided." >&2
    usage
    exit 1
fi

# Support --date now (case-insensitive)
if [[ -n "$DATE" ]]; then
    if [[ "${DATE}" == "now" ]]; then
        DATE="$(date +%Y-%m-%d)"
    fi
fi

echo "########################################" | tee -a "$PIPELINE_LOG"
echo "$SCRIPT_NAME" | tee -a "$PIPELINE_LOG"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$PIPELINE_LOG"
echo "Date: $DATE" | tee -a "$PIPELINE_LOG"
echo "Import method: $IMPORT_METHOD" | tee -a "$PIPELINE_LOG"
echo "Dry run: $DRY_RUN" | tee -a "$PIPELINE_LOG"
echo "Verbose: $VERBOSE" | tee -a "$PIPELINE_LOG"
echo "Source: $SOURCE" | tee -a "$PIPELINE_LOG"
echo "Skip download: $SKIP_DOWNLOAD" | tee -a "$PIPELINE_LOG"
echo "Skip unzip: $SKIP_UNZIP" | tee -a "$PIPELINE_LOG"
echo "Skip import: $SKIP_IMPORT" | tee -a "$PIPELINE_LOG"
echo "----------------------------------------" | tee -a "$PIPELINE_LOG"

# Build forwarded args (common)
FORWARD_ARGS=()
[ "$DRY_RUN" = true ] && FORWARD_ARGS+=("--dry-run") || true
[ "$VERBOSE" = true ] && FORWARD_ARGS+=("--verbose") || true
[ -n "$SOURCE" ] && FORWARD_ARGS+=("--source" "$SOURCE") || true
[ "$NO_OVERRIDES" = true ] && FORWARD_ARGS+=("--no-overrides") || true

# Prepare per-step args
DL_ARGS=(${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"})
UNZIP_ARGS=(${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"})
if [[ -n "$DATE" ]]; then
    UNZIP_ARGS+=("--date" "$DATE")
fi
IMPORT_ARGS=(${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"})

# Scripts
DOWNLOAD_SCRIPT="${SCRIPT_DIR}/cvr-download-data.sh"
UNZIP_SCRIPT="${SCRIPT_DIR}/cvr-unzip-data.sh"
case "$IMPORT_METHOD" in
    mysql|direct)
        IMPORT_SCRIPT="${SCRIPT_DIR}/cvr-import-mysql.sh"
        ;;
    php|*)
        IMPORT_SCRIPT="${SCRIPT_DIR}/cvr-import-php.sh"
        ;;
esac

# Generic runner: runs script, logs to per-step logfile and pipeline log, exits on failure
run_step() {
    local name="$1"
    local script="$2"
    shift 2
    local args=("$@")

    local name_lower="$(tr '[:upper:]' '[:lower:]' <<<"${name:0:1}")${name:1}"
    local step_log_file="${LOG_DIR}/${name_lower// /-}-${LOG_SUFFIX}.log"

    echo "===== STEP: $name =====" | tee -a "$PIPELINE_LOG"
    echo "Command: $script ${args[*]:-}" | tee -a "$PIPELINE_LOG"

    if [[ "$DRY_RUN" = true ]]; then
        echo "[DRY RUN] Would run: $script ${args[*]:-}" | tee -a "$PIPELINE_LOG"
        echo "[DRY RUN] No logfile created for step $name" | tee -a "$PIPELINE_LOG"
        return 0
    fi

    if [[ ! -x "$script" ]]; then
        # If the script is not executable, try to run with bash
        if [[ -f "$script" ]]; then
            echo "Note: $script is not executable; invoking with bash" | tee -a "$PIPELINE_LOG"
            bash "$script" ${args[@]+"${args[@]}"} 2>&1
            local ec=${PIPESTATUS[0]}
        else
            echo "ERROR: Script not found: $script" | tee -a "$PIPELINE_LOG"
            return 127
        fi
    else
        "$script" ${args[@]+"${args[@]}"} 2>&1
        local ec=${PIPESTATUS[0]}
    fi

    if [[ $ec -ne 0 ]]; then
        echo "[ERROR] Step '$name' failed with exit code $ec" | tee -a "$PIPELINE_LOG"
        echo "See step log: $step_log_file" | tee -a "$PIPELINE_LOG"
        echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$PIPELINE_LOG"
        exit $ec
    fi

    echo "[OK] Step '$name' completed" | tee -a "$PIPELINE_LOG"
    return 0
}

# Execute steps sequentially (respect skip flags)
if [[ "$SKIP_DOWNLOAD" = true ]]; then
    echo "[SKIP] Download step skipped" | tee -a "$PIPELINE_LOG"
else
    run_step "Download" "$DOWNLOAD_SCRIPT" ${DL_ARGS[@]+"${DL_ARGS[@]}"}
fi

if [[ "$SKIP_UNZIP" = true ]]; then
    echo "[SKIP] Unzip step skipped" | tee -a "$PIPELINE_LOG"
else
    run_step "Unzip" "$UNZIP_SCRIPT" ${UNZIP_ARGS[@]+"${UNZIP_ARGS[@]}"}
fi

if [[ "$SKIP_IMPORT" = true ]]; then
    echo "[SKIP] Import step skipped" | tee -a "$PIPELINE_LOG"
else
    run_step "Import" "$IMPORT_SCRIPT" ${IMPORT_ARGS[@]+"${IMPORT_ARGS[@]}"}
fi

# Finish
echo "----------------------------------------" | tee -a "$PIPELINE_LOG"
echo "Pipeline completed successfully: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$PIPELINE_LOG"
echo "Logs: $LOG_DIR" | tee -a "$PIPELINE_LOG"
echo "########################################" | tee -a "$PIPELINE_LOG"

exit 0
