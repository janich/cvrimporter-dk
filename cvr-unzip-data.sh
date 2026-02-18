#!/usr/bin/env bash
################################################################################
# CVR Data Unzip Script
#
# Unzips previously downloaded CVR data files.
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
#   ./cvr-unzip-data.sh [options]
#
# Options:
#   --date YYYY-MM-DD   Unzip data from specific date folder (default: today)
#   --source NAME       Unzip only a specific source (e.g., "Telefaxnummer")
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
SCRIPT_NAME="CVR Data Unzip"

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

source "${SCRIPT_DIR}/lib/unzip.sh" || {
    echo "ERROR: Failed to load unzip functions from ${SCRIPT_DIR}/lib/unzip.sh"
    exit 1
}

# =============================================================================
# SCRIPT-SPECIFIC CONFIGURATION
# =============================================================================

DRY_RUN=false
SINGLE_SOURCE=""

# Derived paths
DOWNLOAD_DIR=""
UNZIP_DIR=""

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat << EOF
$SCRIPT_NAME

Unzips previously downloaded CVR data files.

Usage: $(basename "$0") [options]

Options:
    --date YYYY-MM-DD   Unzip data from specific date folder (default: today)
    --source NAME       Unzip only a specific source (e.g., "Telefaxnummer")
    --dry-run           Show what would be done without executing
    --verbose           Enable verbose output
    --quiet             Disable most output
    --help              Show this help message

Environment variables:
    CVR_DATA_DIR                Base data directory (default: ./data)
    CVR_LOG_DIR                 Log directory (default: ./logs)
    CVR_VERBOSE                 Enable verbose output

Examples:
    # Unzip today's downloaded data
    ./$(basename "$0")

    # Unzip data from specific date folder
    ./$(basename "$0") --date 2026-02-16

    # Unzip only Telefonnummer
    ./$(basename "$0") --source Telefaxnummer

    # Dry run to see what would happen
    ./$(basename "$0") --dry-run

EOF
}


# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --date)
                DATE_SUFFIX="$2"
                shift 2
                ;;
            --date=*)
                DATE_SUFFIX="${1#*=}"
                shift
                ;;
            --source)
                SINGLE_SOURCE="$2"
                shift 2
                ;;
            --source=*)
                SINGLE_SOURCE="${1#*=}"
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
    # Parse arguments first
    parse_args "$@"

    # Set derived paths after config is loaded
    DOWNLOAD_DIR="${DATA_DIR}/${DATE_SUFFIX}"
    UNZIP_DIR="$(get_unzip_dir "")"

    # Set log file
    LOG_FILE="${LOG_DIR}/unzip-${LOG_SUFFIX}.log"

    # Validate date format
    if ! validate_date_format "$DATE_SUFFIX"; then
        log_error "Invalid date format: $DATE_SUFFIX (expected YYYY-MM-DD)"
        exit 1
    fi

    # Check if download directory exists
    if [[ ! -d "$DOWNLOAD_DIR" ]]; then
        log_error "Download directory not found: $DOWNLOAD_DIR"
        exit 1
    fi

    # Initialize logging
    log_info "========================================"
    log_info "$SCRIPT_NAME"
    log_info "========================================"
    log_info "Date:           $DATE_SUFFIX"
    log_info "Download dir:   $DOWNLOAD_DIR"
    log_info "Unzip dir:      $UNZIP_DIR"
    log_info "Log file:       $LOG_FILE"
    log_info "========================================"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No actual operations will be performed"
    fi

    # Ensure directories exist
    ensure_directory "$UNZIP_DIR" || exit 1
    ensure_directory "$LOG_DIR" || exit 1

    log_info ""

    # Process statistics
    local total_sources=0
    local unzipped=0
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
        log_info "Unzipping: $name"

        local filename=$(build_filename "$name" "$version" "$url_part" "$download_type" "$file_type" "$data_type")
        local zip_file="${DOWNLOAD_DIR}/${filename}"

        # Check if zip file exists
        if [[ ! -f "$zip_file" ]] && [[ "$DRY_RUN" != "true" ]]; then
            log_warn "Zip file not found: $zip_file, skipping..."
            log_warn "----------------------------------------"
            log_warn ""

            ((errors++))
            continue
        fi

        # Unzip
        unzip_file "$name" "$zip_file" || {
            log_error "Unzip failed for $name, continuing to next..."
            log_error "----------------------------------------"
            log_error ""

            ((errors++))
            continue
        }

        ((unzipped++))

        log_info "----------------------------------------"
        log_info ""
    done

    local script_elapsed=$(elapsed_time $script_start)

    # Summary
    log_info "========================================"
    log_info "SUMMARY"
    log_info "========================================"
    log_info "Total sources:  $total_sources"
    log_info "Unzipped:       $unzipped"
    log_info "Errors:         $errors"
    log_info "Total time:     $script_elapsed"
    log_info "Log file:       $LOG_FILE"
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
