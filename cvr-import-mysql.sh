#!/usr/bin/env bash
################################################################################
# CVR Data Import Script - Direct MySQL Method
#
# Imports CVR CSV files directly into MySQL using LOAD DATA.
# Creates tables with dynamic schema based on CSV headers.
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
# Usage:
#   ./cvr-import-mysql.sh [options]
#
# Options:
#   --source NAME       Import only a specific source (e.g., "Telefaxnummer")
#   --dry-run           Show what would be done without executing
#   --verbose           Enable verbose output
#   --quiet             Disable most output
#   --help              Show this help message
#
################################################################################

set -o pipefail

# =============================================================================
# INITIALIZATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="CVR Import - MySQL Direct Method"

# Load config file
source "${SCRIPT_DIR}/cvr.conf" || {
    echo "ERROR: Failed to load configuration from ${SCRIPT_DIR}/cvr.conf"
    exit 1
}

# Source libraries
source "${SCRIPT_DIR}/lib/common.sh" || {
    echo "ERROR: Failed to load common functions from ${SCRIPT_DIR}/lib/common.sh"
    exit 1
}

source "${SCRIPT_DIR}/lib/import.sh" || {
    echo "ERROR: Failed to load import functions from ${SCRIPT_DIR}/lib/import.sh"
    exit 1
}

source "${SCRIPT_DIR}/lib/import-mysql.sh" || {
    echo "ERROR: Failed to load MySQL import functions from ${SCRIPT_DIR}/lib/import-mysql.sh"
    exit 1
}

# =============================================================================
# SCRIPT-SPECIFIC CONFIGURATION
# =============================================================================

DRY_RUN=false
SINGLE_SOURCE=""
NO_OVERRIDES=false

# CSV parsing configuration
CSV_DELIMITER="${CVR_CSV_DELIMITER:-,}"
CSV_ENCLOSURE="${CVR_CSV_ENCLOSURE:-\"}"
CSV_LINE_TERMINATOR="${CVR_CSV_LINE_TERMINATOR:-\\n}"

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat << EOF
$SCRIPT_NAME

Imports CVR CSV files directly into MySQL using LOAD DATA command.

Usage: $(basename "$0") [options]

Options:
    --source NAME       Import only a specific source (e.g., "Telefaxnummer")
    --dry-run           Show what would be done without executing
    --verbose           Enable verbose output
    --quiet             Disable most output
    --help              Show this help message

Environment variables:
    CVR_DATA_DIR                Base data directory
    CVR_DB_HOST                 Database host
    CVR_DB_PORT                 Database port
    CVR_DB_NAME                 Database name
    CVR_DB_USER                 Database user
    CVR_DB_PASS                 Database password
    CVR_DB_PREFIX               Table prefix for imports (default: cvr_import_)
    CVR_CSV_DELIMITER           CSV field delimiter (default: ,)
    CVR_CSV_ENCLOSURE           CSV field enclosure (default: ")
    CVR_CSV_LINE_TERMINATOR     CSV field line termination (default: \n)
    CVR_LOG_DIR                 Log directory (default: ./logs)
    CVR_VERBOSE                 Enable verbose output

Examples:
    # Import today's data
    ./$(basename "$0")

    # Import only Telefaxnummer data
    ./$(basename "$0") --source Telefaxnummer

    # Dry run to see what would happen
    ./$(basename "$0") --dry-run

    # Import with verbose output
    ./$(basename "$0") --verbose

EOF
}


# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)
                SINGLE_SOURCE="$2"
                shift 2
                ;;
            --source=*)
                SINGLE_SOURCE="${1#*=}"
                shift
                ;;
            --no-overrides)
                NO_OVERRIDES=true
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
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Parse arguments
    parse_args "$@"

    # Initialize
    init_import_script "$SCRIPT_NAME" "import-mysql"

    # Additional info for MySQL method
    log_info "DB Host:        $DB_HOST:$DB_PORT"
    log_info "DB Name:        $DB_NAME"
    log_info "========================================"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No actual operations will be performed"
    else
        local mysql_check_output=$(execute_mysql "SELECT 1;" 2>&1)

        local mysql_check_exit=$?
        if [[ $mysql_check_exit -ne 0 ]]; then
            log_error " --> MySQL connectivity failed: $mysql_check_output"
            log_error ""
            return 1
        fi
    fi

    log_info ""

    # Process statistics
    local total_sources=0
    local imported=0
    local errors=0
    local script_start=$(date +%s)

    # Process each data source
    for source in "${DATA_SOURCES[@]}"; do
        IFS='|' read -r name version url_part download_type file_type data_type timeout <<< "$source"

        # Skip if single source specified and doesn't match
        if [[ -n "$SINGLE_SOURCE" ]] && [[ "$name" != "$SINGLE_SOURCE" ]]; then
            continue
        fi

        ((total_sources++))

        log_info "----------------------------------------"
        log_info "Importing: $name"

        # Get unzip directory
        local unzip_dir=$(get_unzip_dir "$name")

        if [[ ! -d "$unzip_dir" ]]; then
            log_error "Directory not found: $unzip_dir, skipping..."
            log_error "----------------------------------------"
            log_error ""

            ((errors++))
            continue
        fi

        # Import
        import_csv_mysql "$name" "$unzip_dir" || {
            log_warn "Import failed for $name, continuing to next..."
            log_warn "----------------------------------------"
            log_warn ""
            ((errors++))
            continue
        }

        ((imported++))

        log_info "----------------------------------------"
        log_info ""
    done

    local script_elapsed=$(elapsed_time $script_start)

    # Summary
    log_info "========================================"
    log_info "SUMMARY"
    log_info "========================================"
    log_info "Total sources:  $total_sources"
    log_info "Imported:       $imported"
    log_info "Errors:         $errors"
    log_info "Total time:     $script_elapsed"
    log_info "========================================"

    if [[ $errors -gt 0 ]]; then
        log_warn "Completed with $errors error(s)"
        log_warn ""
        return 1
    fi

    log_info "Completed successfully!"
    log_info ""

    return 0
}

# Run main function
main "$@"
