#!/usr/bin/env bash
################################################################################
# Download Library - CVR Data Download Functions
#
# Provides functions for downloading data.
# This file is sourced by download scripts and should not be executed directly.
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
# DOWNLOAD CONFIGURATION (can be overridden by sourcing script)
# =============================================================================

: "${API_BASE_URL:=}"
: "${API_KEY:=}"
: "${CURL_TIMEOUT:=300}"
: "${CURL_CONNECT_TIMEOUT:=10}"
: "${CACHE_THRESHOLD_BYTES:=10485760}"  # 10MB

# =============================================================================
# DOWNLOAD FUNCTIONS
# =============================================================================

# Build complete URL for download
build_download_url() {
    local filename="$1"
    echo "${API_BASE_URL}?Filename=${filename}&apikey=${API_KEY}"
}

# Download a single file with caching and error handling
download_file() {
    local name="$1"
    local filename="$2"
    local timeout="${3:-$CURL_TIMEOUT}"
    local local_file="${DOWNLOAD_DIR}/${filename}"

    local url=$(build_download_url "$filename")

    log_debug "From URL: ${API_BASE_URL}?Filename=${filename}&apikey=***"
    log_debug "To file: $local_file"

    # Check cache
    if file_exists_and_valid "$local_file" "$CACHE_THRESHOLD_BYTES"; then
        local size=$(get_file_size "$local_file")
        log_info " --> Is cached: $(human_readable_size $size)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " --> [DRY RUN] Would download: $filename"
        return 0
    fi

    # Ensure directory exists
    ensure_directory "$(dirname "$local_file")" || return 1

    # Remove partial download
    rm -f "$local_file" 2>/dev/null || true

    local start_time=$(date +%s)

    # Download with curl
    local http_code
    http_code=$(curl -s -w "%{http_code}" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "${timeout}" \
        -H "Accept: application/octet-stream" \
        -o "$local_file" \
        "$url" 2>&1) || {
        log_error " --> Download failed for $name (curl error)"

        if file_exists_and_valid "$local_file" 100; then
                local size=$(get_file_size "$local_file")
                local elapsed=$(elapsed_time $start_time)
                log_error " --> Downloaded: $(human_readable_size $size) in $elapsed"
        fi

        rm -f "$local_file" 2>/dev/null || true
        return 1
    }

    # Check HTTP status
    if [[ "$http_code" != "200" ]]; then
        log_error " --> Download failed for $name (HTTP $http_code)"

        if file_exists_and_valid "$local_file" 100; then
                local size=$(get_file_size "$local_file")
                local elapsed=$(elapsed_time $start_time)
                log_error " --> Downloaded: $(human_readable_size $size) in $elapsed"
        fi

        rm -f "$local_file" 2>/dev/null || true
        return 1
    fi

    # Verify download
    if file_exists_and_valid "$local_file" 100; then
        local size=$(get_file_size "$local_file")
        local elapsed=$(elapsed_time $start_time)
        log_info " --> Downloaded: $(human_readable_size $size) in $elapsed"
        return 0
    else
        log_error " --> Download incomplete or corrupted for $name"
        rm -f "$local_file" 2>/dev/null || true
        return 1
    fi
}

# Validate API configuration
validate_download_config() {
    if [[ -z "$API_KEY" ]]; then
        log_error "API key is required. Set CVR_API_KEY or add it to config file."
        return 1
    fi

    if [[ -z "$API_BASE_URL" ]]; then
        log_error "API base URL is required. Set CVR_API_BASE_URL or add it to config file."
        return 1
    fi

    return 0
}

