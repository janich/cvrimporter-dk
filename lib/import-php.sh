#!/usr/bin/env bash
################################################################################
# Import PHP Library - CVR Data Import via PHP (mysqli)
#
# Provides functions for importing CSV data using PHP with mysqli driver.
# Can use LOAD DATA LOCAL INFILE via PHP for better performance and flexibility.
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
# PHP IMPORT CONFIGURATION
# =============================================================================

: "${USE_LOCAL_INFILE:=false}"
: "${PHP_BIN:=php}"

# =============================================================================
# PHP HELPER GENERATION
# =============================================================================

# Create and execute PHP import helper script
php_import_helper() {
    local table_name="$1"
    local csv_file="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info " --> [DRY RUN] Would run PHP importer for table $table_name from file $csv_file"
        return 0
    fi

    local php_tmp
    php_tmp=$(mktemp /tmp/cvr_import_php.XXXXXX.php)

    # Generate PHP script inline
    cat > "$php_tmp" <<'PHPSCRIPT'
<?php
$table = $argv[1] ?? null;
$csv = $argv[2] ?? null;
$host = getenv('DB_HOST') ?: '127.0.0.1';
$port = getenv('DB_PORT') ?: '3306';
$db = getenv('DB_NAME') ?: 'devtoolsapi';
$user = getenv('DB_USER') ?: 'root';
$pass = getenv('DB_PASS') ?: '';
$prefix = getenv('DB_PREFIX') ?: 'cvr_import_';
$delim = getenv('CSV_DELIM');
$enc = getenv('CSV_ENC');
$escape = '\\';
$lineTerm = getenv('CSV_LINE_TERM');
$useLocal = strtolower(getenv('USE_LOCAL_INFILE') ?: 'false');
$overrideDir = getenv('OVERRIDE_DIR') ?: null;

if (!$table || !$csv) {
    fwrite(STDERR, "Missing arguments to PHP importer\n");
    exit(2);
}

// Normalize delimiters
if ($delim === null || $delim === '') $delim = ',';
if ($enc === null) $enc = '"';
if ($lineTerm === null || $lineTerm === '') $lineTerm = "\n";

// Connect
$mysqli = mysqli_init();
if ($useLocal === '1' || $useLocal === 'true') {
    @mysqli_options($mysqli, MYSQLI_OPT_LOCAL_INFILE, true);
}
if (!mysqli_real_connect($mysqli, $host, $user, $pass, $db, (int)$port)) {
    fwrite(STDERR, "CONNECT ERROR: " . mysqli_connect_error() . "\n");
    exit(3);
}

// Read CSV headers
$handle = @fopen($csv, 'r');
if (!$handle) {
    fwrite(STDERR, "Cannot open CSV: $csv\n");
    exit(4);
}
$headers = fgetcsv($handle, 0, $delim, $enc, $escape);
if ($headers === false) {
    fwrite(STDERR, "Cannot read CSV headers: $csv\n");
    fclose($handle);
    exit(5);
}

// Sanitize function
$sanitize = function($col) {
    $col = trim($col);
    $col = strtolower($col);
    $col = preg_replace('/[^a-z0-9]/', '_', $col);
    $col = preg_replace('/_+/', '_', $col);
    $col = trim($col, '_');
    if ($col === '') $col = 'col_unknown';
    if (in_array($col, ['id','created_at','updated_at','deleted_at'])) {
        $col = 'col_' . $col;
    }
    return $col;
};

$cols = [];
foreach ($headers as $h) {
    $cols[] = $sanitize($h);
}

// Build override map
$overrides = [];
if ($overrideDir !== null) {
    $fullPath = rtrim($overrideDir, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . $table . '.conf';
    $short = $table;
    if (strpos($table, $prefix) === 0) {
        $short = substr($table, strlen($prefix));
    }
    $shortPath = rtrim($overrideDir, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . $short . '.conf';

    foreach ([$fullPath, $shortPath] as $f) {
        if (file_exists($f)) {
            $lines = file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            foreach ($lines as $line) {
                $line = preg_replace('/#.*$/', '', $line);
                $line = trim($line);
                if ($line === '') continue;
                if (preg_match('/^([^=]+)=(.+)$/', $line, $m)) {
                    $key = strtolower(trim($m[1]));
                    $key = preg_replace('/[^a-z0-9]/', '_', $key);
                    $val = trim($m[2]);
                    $overrides[$key] = $val;
                }
            }
        }
    }
}

// Build CREATE TABLE
$colDefs = [];
foreach ($cols as $c) {
    $type = 'TEXT';
    if (isset($overrides[$c]) && $overrides[$c] !== '') {
        $type = $overrides[$c];
    }
    $colDefs[] = "`$c` $type";
}
$createSQL = "DROP TABLE IF EXISTS `{$table}`; CREATE TABLE `{$table}` (id BIGINT AUTO_INCREMENT PRIMARY KEY, " . implode(', ', $colDefs) . ", created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;";

if (!$mysqli->multi_query($createSQL)) {
    fwrite(STDERR, "CREATE TABLE failed: " . $mysqli->error . "\n");
    fclose($handle);
    exit(6);
}
while ($mysqli->more_results() && $mysqli->next_result()) { $mysqli->use_result(); }

if ($useLocal === '1' || $useLocal === 'true') {
    // LOAD DATA LOCAL INFILE
    $csvEsc = str_replace("'", "\\'", $csv);
    $columnsList = implode(', ', array_map(function($c){ return "`$c`"; }, $cols));
    $loadSQL = "LOAD DATA LOCAL INFILE '{$csvEsc}' INTO TABLE `{$table}` CHARACTER SET utf8mb4 FIELDS TERMINATED BY '" . addslashes($delim) . "' ENCLOSED BY '" . addslashes($enc) . "' LINES TERMINATED BY '" . addslashes($lineTerm) . "' IGNORE 1 ROWS ({$columnsList});";

    if (!$mysqli->query($loadSQL)) {
        fwrite(STDERR, "LOAD DATA failed: " . $mysqli->error . "\n");
        fclose($handle);
        exit(7);
    }
} else {
    // Fallback: batched multi-row INSERTs
    $batchSize = 500;
    $rows = [];
    $rowCount = 0;
    while (($data = fgetcsv($handle, 0, $delim, $enc, $escape)) !== false) {
        $vals = [];
        foreach ($data as $v) {
            $v = $mysqli->real_escape_string($v);
            $vals[] = "'" . $v . "'";
        }
        // Pad with NULLs if needed
        if (count($vals) < count($cols)) {
            $vals = array_merge($vals, array_fill(0, count($cols) - count($vals), "''"));
        }
        $rows[] = '(' . implode(',', $vals) . ')';
        $rowCount++;

        if ($rowCount >= $batchSize) {
            $columnsList = implode(', ', array_map(function($c){ return "`$c`"; }, $cols));
            $insertSQL = "INSERT INTO `{$table}` ({$columnsList}) VALUES " . implode(', ', $rows) . ";";
            if (!$mysqli->query($insertSQL)) {
                fwrite(STDERR, "INSERT batch failed: " . $mysqli->error . "\n");
                fclose($handle);
                exit(8);
            }
            $rows = [];
            $rowCount = 0;
        }
    }
    // Final batch
    if ($rowCount > 0) {
        $columnsList = implode(', ', array_map(function($c){ return "`$c`"; }, $cols));
        $insertSQL = "INSERT INTO `{$table}` ({$columnsList}) VALUES " . implode(', ', $rows) . ";";
        if (!$mysqli->query($insertSQL)) {
            fwrite(STDERR, "INSERT final batch failed: " . $mysqli->error . "\n");
            fclose($handle);
            exit(9);
        }
    }
}

fclose($handle);
$mysqli->close();
exit(0);
PHPSCRIPT

    # Export environment for PHP
    export DB_HOST
    export DB_PORT
    export DB_NAME
    export DB_USER
    export DB_PASS
    export DB_PREFIX
    export CSV_DELIM="${CSV_DELIMITER}"
    export CSV_ENC="${CSV_ENCLOSURE}"
    export CSV_LINE_TERM="${CSV_LINE_TERMINATOR}"
    export USE_LOCAL_INFILE

    if [[ "$NO_OVERRIDES" != "true" ]]; then
        export OVERRIDE_DIR="${SCRIPT_DIR}/overrides"
    else
        unset OVERRIDE_DIR 2>/dev/null || true
    fi

    # Execute PHP script
    "$PHP_BIN" -d mysqli.allow_local_infile=1 "$php_tmp" "$table_name" "$csv_file"
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        log_error "PHP import failed for $csv_file -> rc=$rc"
    fi

    rm -f "$php_tmp"
    return $rc
}

# Main import function for PHP method
import_csv_php() {
    local name="$1"
    local csv_dir="$2"

    log_info "Importing (PHP): $name"
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
        log_debug " --> Processing: $csv_basename -> table: $table_name"

        if php_import_helper "$table_name" "$csv_file"; then
            ((imported_count++))
            log_info " --> Imported: $csv_basename -> $table_name"
        else
            ((error_count++))
            log_warn " --> Failed to import: $csv_basename"
        fi
    done

    local elapsed=$(elapsed_time $start_time)
    log_info " --> Completed: $imported_count of ${#csv_files[@]} file(s) in $elapsed"

    [[ $error_count -eq 0 ]]
}

