#!/usr/bin/env bash
################################################################################
# Common functions and configuration for CVR import scripts
#
# This file is sourced by the import scripts and should not be executed directly.
#
# Copyright (c) 2026 janich.dk
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
################################################################################

# Prevent direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This script should be sourced, not executed directly."
    exit 1
fi

# =============================================================================
# DEFAULT CONFIGURATION
# =============================================================================

# Script directory (set by sourcing script)
: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Directory Configuration
DATA_DIR="${CVR_DATA_DIR:-$SCRIPT_DIR/data}"
DATE_SUFFIX="$(date +%Y-%m-%d)"

# Database Configuration
DB_HOST="${CVR_DB_HOST:-127.0.0.1}"
DB_PORT="${CVR_DB_PORT:-3306}"
DB_NAME="${CVR_DB_NAME:-}"
DB_USER="${CVR_DB_USER:-}"
DB_PASS="${CVR_DB_PASS:-}"
DB_PREFIX="${CVR_DB_PREFIX:-import_}"

# Logging Configuration
LOG_DIR="${CVR_LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_SUFFIX="${CVR_LOG_SUFFIX:-$(date +%Y-%m)}"
VERBOSE="${CVR_VERBOSE:-false}"

# =============================================================================
# DATA SOURCES CONFIGURATION
# Format: NAME|VERSION|URL_PART|DOWNLOAD_TYPE|FILE_TYPE|DATA_TYPE|TIMEOUT
# =============================================================================
declare -a DATA_SOURCES=${DATA_SOURCES:-()}

# =============================================================================
# COLOR CODES
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        INFO)  local color="$GREEN" ;;
        WARN)  local color="$YELLOW" ;;
        ERROR) local color="$RED" ;;
        DEBUG) local color="$BLUE" ;;
        *)     local color="$NC" ;;
    esac

    # Console output
    if [[ "$VERBOSE" == "true" ]] || [[ "$level" != "DEBUG" ]]; then
        echo -e "${color}[$timestamp] [$level] $message${NC}"
    fi

    # Ensure log directory exists
    ensure_directory "$LOG_DIR" || return 0

    # File output (strip color codes)
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { log "DEBUG" "$@"; }

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

human_readable_size() {
    local bytes=$1

    # Validate input is numeric
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0 bytes"
        return 1
    fi

    if [[ $bytes -ge 1073741824 ]]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2f GB\n", b/1073741824}' | tr -d '\n'
    elif [[ $bytes -ge 1048576 ]]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2f MB\n", b/1048576}' | tr -d '\n'
    elif [[ $bytes -ge 1024 ]]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2f KB\n", b/1024}' | tr -d '\n'
    else
        echo "$bytes bytes"
    fi
}

elapsed_time() {
    local start=$1
    local end=$(date +%s)
    local diff=$((end - start))
    echo "${diff}s"
}

ensure_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null || {
            echo "Failed to create directory: $dir" >&2
            return 1
        }
    fi
    return 0
}

clean_directory() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
      rm -rf "${dir:?}"/* 2>/dev/null || {
          echo "Failed to clean directory: $dir" >&2
          return 1
      }
    fi
    return 0
}

file_exists_and_valid() {
    local file="$1"
    local min_size="${2:-0}"

    [[ -f "$file" ]] && [[ $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null) -ge $min_size ]]
}

get_file_size() {
    local file="$1"
    stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0
}

build_filename() {
    local name="$1"
    local version="$2"
    local url_part="$3"
    local download_type="$4"
    local file_type="$5"
    local data_type="$6"

    echo "CVR_${version}_${url_part}_${download_type}_${file_type}_${data_type}_289.zip"
}

# Get the unzipped directory path for a data source
get_unzip_dir() {
    local name="$1"
    echo "${DATA_DIR}/unzipped/${name}"
}

# =============================================================================
# TABLE NAME FUNCTIONS
# =============================================================================

# Generate a clean table name from source name
generate_table_name() {
    local name="$1"
    local prefix="${2:-$DB_PREFIX}"

    # Clean the name: lowercase, replace special chars with underscore
    local clean_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//' | sed 's/_$//')

    echo "${prefix}${clean_name}"
}

# Sanitize a column name
sanitize_column_name() {
    local col="$1"

    # Remove quotes and clean
    col=$(echo "$col" | tr -d '"' | tr -d "'" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//' | sed 's/_$//')

    # Handle empty column names
    [[ -z "$col" ]] && col="col_unknown"

    # Handle reserved column names
    case "$col" in
        id|created_at|updated_at|deleted_at)
            col="col_${col}"
            ;;
    esac

    echo "$col"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

validate_date_format() {
    local date="$1"
    if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        return 1
    fi
    return 0
}

validate_data_directory() {
    local date_suffix="$1"
    local data_path="${DATA_DIR}/unzipped"

    if [[ ! -d "$data_path" ]]; then
        log_error "Data directory not found: $data_path"
        return 1
    fi

    return 0
}

# =============================================================================
# INITIALIZATION
# =============================================================================

init_import_script() {
    local script_name="$1"
    local log_prefix="$2"

    # Set log file
    LOG_FILE="${LOG_DIR}/${log_prefix}-${LOG_SUFFIX}.log"

    # Log initialization
    log_info "========================================"
    log_info "$script_name"
    log_info "========================================"
    log_info "Data directory: $DATA_DIR"
    log_info "Log file:       $LOG_FILE"
    log_info "DB Prefix:      $DB_PREFIX"
}

# =============================================================================
# COLUMN OVERRIDES (new)
#
# Provide per-table column type overrides in a simple key=value format.
# Place files under: ${SCRIPT_DIR}/overrides/
# File name candidates:
#   - <full_table_name>.conf   (e.g. cvr_import_telefaxnummer.conf)
#   - <shortname>.conf         (e.g. telefaxnummer.conf)
#
# File format (one mapping per line):
#   sanitized_column_name=SQL_TYPE
# Example:
#   telefaxnummer=VARCHAR(100) NULL
#   antal_ansatte=INT NULL
# =============================================================================
get_column_override() {
    local table="$1"
    local column="$2"
    local short

    # Remove DB_PREFIX if present to form the short name
    if [[ -n "$DB_PREFIX" && "$table" == ${DB_PREFIX}* ]]; then
        short="${table#${DB_PREFIX}}"
    else
        short="$table"
    fi

    local override_dir="${SCRIPT_DIR}/overrides"
    local candidates=("${override_dir}/${table}.conf" "${override_dir}/${short}.conf")

    local sanitized_col
    sanitized_col=$(sanitize_column_name "$column")

    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            # Read file and look for key match (allow spaces around =)
            while IFS= read -r line || [[ -n "$line" ]]; do
                # strip comments and trim
                line="$(echo "$line" | sed 's/#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
                [[ -z "$line" ]] && continue
                if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
                    local key="${BASH_REMATCH[1]}"
                    local val="${BASH_REMATCH[2]}"
                    key="$(echo "$key" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')"
                    val="$(echo "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
                    if [[ "$key" == "$sanitized_col" ]]; then
                        echo "$val"
                        return 0
                    fi
                fi
            done < "$f"
        fi
    done

    # No override found
    echo ""
    return 0
}

