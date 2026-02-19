#!/usr/bin/env bash
################################################################################
# Unzip Library - CVR Data Unzip Functions
#
# Provides functions for unzipping downloaded CVR data files.
# This file is sourced by unzip scripts and should not be executed directly.
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
# UNZIP FUNCTIONS
# =============================================================================

# Unzip a single file with caching
unzip_file() {
    local name="$1"
    local zip_file="$2"
    local output_dir=$(get_unzip_dir "$name")

    log_debug "Unzipping: "
    log_debug " -- Source: $zip_file"
    log_debug " -- To folder: $output_dir"

    # Check if zip file exists
    if [[ ! -f "$zip_file" ]]; then
        log_error "Unzip: Zip file not found: $name"
        log_error " --> Zip file: $zip_file"
        return 1
    fi

    # Clean directory before unzipping
    if [[ -d "$output_dir" ]]; then
        clean_directory "$output_dir" || return 1
    fi

    # Check cache
    if [[ -d "$output_dir" ]] && [[ -n "$(ls -A "$output_dir" 2>/dev/null)" ]]; then
        local file_count=$(find "$output_dir" -type f | wc -l | tr -d ' ')
        log_info " --> Cached: $file_count file(s)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " --> [DRY RUN] Would unzip to: $output_dir"
        return 0
    fi

    # Ensure directory exists
    ensure_directory "$output_dir" || return 1

    local start_time=$(date +%s)

    # Unzip
    if ! unzip -o -q -d "$output_dir" "$zip_file" 2>/dev/null; then
        log_error "Unzip: Unzip failed for $name"
        log_error " --> Zip file: $zip_file"
        log_error " --> To path: $output_dir"
        rm -rf "$output_dir" 2>/dev/null || true
        return 1
    fi

    local file_count=$(find "$output_dir" -type f | wc -l | tr -d ' ')
    local file_size=$(get_file_size "$zip_file")
    local elapsed=$(elapsed_time $start_time)

    log_info " --> Unzipped: $(human_readable_size $file_size) to $file_count file(s) in $elapsed"

    return 0
}
