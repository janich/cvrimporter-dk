#!/usr/bin/env bash
################################################################################
# Import Library - Common CVR Data Import Functions
#
# Provides shared functions for CSV import operations (both MySQL and PHP methods).
# This file is sourced by import scripts and should not be executed directly.
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
# IMPORT CONFIGURATION (can be overridden)
# =============================================================================

: "${CSV_DELIMITER:=,}"
: "${CSV_ENCLOSURE:=\"}"
: "${CSV_LINE_TERMINATOR:=\\n}"
: "${NO_OVERRIDES:=false}"

# =============================================================================
# CSV PARSING FUNCTIONS
# =============================================================================

# Parse CSV headers and prepare column information
parse_csv_headers() {
    local csv_file="$1"

    # Read first line to get headers
    local headers
    headers=$(head -n 1 "$csv_file" 2>/dev/null | tr -d '\r') || {
        log_debug "CSV: Cannot read headers from $csv_file"
        return 1
    }

    if [[ -z "$headers" ]]; then
        log_debug "CSV: Empty headers in $csv_file"
        return 1
    fi

    # Parse headers into array
    local columns=()
    local column_list=()

    # Use awk to properly parse CSV headers
    # Escape the delimiter for awk to avoid syntax errors
    local awk_delim="${CSV_DELIMITER//\\/\\\\}"  # Escape backslashes
    awk_delim="${awk_delim//\"/\\\"}"             # Escape quotes

    while IFS= read -r col; do
        local clean_col=$(sanitize_column_name "$col")
        columns+=("$clean_col")
        column_list+=("\`${clean_col}\`")
    done < <(echo "$headers" | awk -v FS="$awk_delim" '{
        for(i=1; i<=NF; i++) {
            gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", $i)
            print $i
        }
    }')

    # Output for use in calling script
    PARSED_COLUMNS=("${columns[@]}")
    PARSED_COLUMN_LIST=$(IFS=','; echo "${column_list[*]}")
}

# Get column type override from config file
get_column_override() {
    local table="$1"
    local column="$2"
    local override_type=""

    if [[ "$NO_OVERRIDES" == "true" ]]; then
        echo ""
        return 0
    fi

    # Try to get override (function defined in common.sh)
    if declare -f get_column_override >/dev/null 2>&1; then
        # Avoid recursion - use the common.sh version
        override_type=$(get_column_override "$table" "$column" 2>/dev/null || true)
    fi

    echo "$override_type"
}

# Build CREATE TABLE statement with column definitions
build_create_table_sql() {
    local table_name="$1"
    shift
    local columns=("$@")

    local col_defs=""
    for col in "${columns[@]}"; do
        local override_type=""
        if [[ "${NO_OVERRIDES}" != "true" ]]; then
            override_type=$(get_column_override "$table_name" "$col" || true)
        fi

        if [[ -n "$override_type" ]]; then
            col_def="\`${col}\` ${override_type}"
        else
            col_def="\`${col}\` TEXT"
        fi

        if [[ -n "$col_defs" ]]; then
            col_defs="$col_defs, ${col_def}"
        else
            col_defs="$col_def"
        fi
    done

    echo "DROP TABLE IF EXISTS \`${table_name}\`; CREATE TABLE \`${table_name}\` (id BIGINT AUTO_INCREMENT PRIMARY KEY, ${col_defs}, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
}

# Find CSV files in a directory
find_csv_files() {
    local csv_dir="$1"
    local csv_files=()

    while IFS= read -r -d '' file; do
        csv_files+=("$file")
    done < <(find "$csv_dir" -name "*.csv" -type f -print0 2>/dev/null)

    # Return array via global (can't return arrays directly in bash)
    FOUND_CSV_FILES=("${csv_files[@]}")
}

