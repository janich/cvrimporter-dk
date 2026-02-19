#!/usr/bin/env bash
################################################################################
# Import MySQL Library - CVR Data Import via MySQL LOAD DATA
#
# Provides functions for importing CSV data directly into MySQL using
# LOAD DATA LOCAL INFILE. This file is sourced by MySQL import scripts.
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
# MYSQL UTILITY FUNCTIONS
# =============================================================================

# Build MySQL command arguments (password handled via environment)
build_mysql_cmd() {
    local cmd=("mysql" "-h${DB_HOST}" "-P${DB_PORT}" "-u${DB_USER}" "${DB_NAME}")
    printf '%s' "${cmd[*]}"
}

# Execute a MySQL query
execute_mysql() {
    local query="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_debug " --> [DRY RUN] Would execute: ${query:0:100}..."
        return 0
    fi

    local mysql_bin
    mysql_bin=$(build_mysql_cmd)

    # Use MYSQL_PWD env to avoid exposing password on command line
    local output
    output=$(MYSQL_PWD="$DB_PASS" eval "echo \"$query\" | $mysql_bin" 2>&1)
    local rc=$?
    echo "$output"
    return $rc
}

# =============================================================================
# MYSQL IMPORT FUNCTIONS
# =============================================================================

# Create import table with dynamic schema
create_import_table() {
    local table_name="$1"
    shift
    local columns=("$@")

    log_debug " --> Creating table: $table_name"

    local create_sql
    create_sql=$(build_create_table_sql "$table_name" "${columns[@]}")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " --> [DRY RUN] Would create table: $table_name with ${#columns[@]} columns"
        return 0
    fi

    if ! execute_mysql "$create_sql" >/dev/null; then
        log_error " --> Failed to create table: $table_name"
        return 1
    fi

    log_debug " --> Table created: $table_name"
    return 0
}

# Load CSV data into table using LOAD DATA
load_csv_data() {
    local table_name="$1"
    local csv_file="$2"
    shift 2
    local columns=("$@")

    log_debug " --> Loading data into: $table_name"

    # Build variable list and SET clause for NULLIF handling
    local var_list=()
    local set_statements=()

    for col in "${columns[@]}"; do
        var_list+=("@\`${col}\`")

        # Check if column has override
        local override_type=""
        if [[ "${NO_OVERRIDES}" != "true" ]]; then
            override_type=$(get_column_override "$table_name" "$col" 2>/dev/null || true)
        fi

        if [[ -n "$override_type" ]]; then
            # Column has override - convert empty to NULL
            set_statements+=("\`${col}\` = NULLIF(@\`${col}\`, '')")
        else
            # No override - keep as is
            set_statements+=("\`${col}\` = @\`${col}\`")
        fi
    done

    local var_list_str=$(IFS=','; echo "${var_list[*]}")
    local set_clause=$(IFS=','; echo "${set_statements[*]}")

    local load_sql="LOAD DATA LOCAL INFILE '${csv_file}' INTO TABLE \`${table_name}\` CHARACTER SET utf8mb4 FIELDS TERMINATED BY '${CSV_DELIMITER}' ENCLOSED BY '${CSV_ENCLOSURE}' LINES TERMINATED BY '${CSV_LINE_TERMINATOR}' IGNORE 1 ROWS (${var_list_str}) SET ${set_clause};"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " --> [DRY RUN] Would load data from: $(basename "$csv_file")"
        return 0
    fi

    # Execute using MYSQL_PWD
    local result
    result=$(echo "$load_sql" | MYSQL_PWD="$DB_PASS" $(build_mysql_cmd) --local-infile=1 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error " --> Failed to load data: $result"
        return 1
    fi

    log_debug " --> Data loaded successfully"
    return 0
}

# Main import function for MySQL method
import_csv_mysql() {
    local name="$1"
    local csv_dir="$2"

    log_debug "Source directory: $csv_dir"

    # Find CSV files
    find_csv_files "$csv_dir"
    local csv_files=("${FOUND_CSV_FILES[@]}")

    if [[ ${#csv_files[@]} -eq 0 ]]; then
        log_warn " --> No CSV files found in $csv_dir"
        return 1
    fi

    local start_time=$(date +%s)
    local imported_count=0
    local error_count=0

    for csv_file in "${csv_files[@]}"; do
        local csv_basename=$(basename "$csv_file")
        local table_name=$(generate_table_name "$name")
        local file_size=$(get_file_size "$csv_file")

        log_debug " --> Processing: $csv_basename ($(human_readable_size $file_size)) -> table: $table_name"
        log_info " --> Importing: $csv_basename ($(human_readable_size $file_size)) -> $table_name"

        # Parse CSV headers
        PARSED_COLUMNS=()
        PARSED_COLUMN_LIST=""
        if ! parse_csv_headers "$csv_file"; then
            ((error_count++))
            log_warn " --> Failed to parse headers: $csv_basename"
            continue
        fi

        log_debug " --> Found ${#PARSED_COLUMNS[@]} columns"

        # Create table
        if ! create_import_table "$table_name" "${PARSED_COLUMNS[@]}"; then
            ((error_count++))
            continue
        fi

        # Load data
        if load_csv_data "$table_name" "$csv_file" "${PARSED_COLUMNS[@]}"; then
            ((imported_count++))
            log_info " --> Imported!"
        else
            ((error_count++))
            log_warn " --> Failed to import!"
        fi
    done

    local elapsed=$(elapsed_time $start_time)
    log_info " --> Completed: $imported_count of ${#csv_files[@]} file(s) in $elapsed"

    [[ $error_count -eq 0 ]]
}

