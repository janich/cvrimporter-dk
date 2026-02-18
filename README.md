# CVR Import Scripts

This folder contains the CVR data import pipeline. The pipeline downloads CVR data, unzips it, and imports it into a database.

## Quick Start

```bash
# Run the complete pipeline (download -> unzip -> import) from this folder
./run.sh

# Run for specific date
./run.sh --date 2026-02-16

# Run with MySQL import instead of PHP
./run.sh --import-method mysql

# Dry run to preview
./run.sh --dry-run
```

## What lives in this folder

- `run.sh` — the pipeline runner (Download → Unzip → Import)
- `cvr-*.sh` — individual step scripts (download, unzip, import)
- `lib/` — reusable library modules used by the scripts
- `data/` — downloaded/unzipped data (created by the scripts)
- `logs/` — logs created by the scripts


## Pipeline runner (`run.sh`)

`run.sh` orchestrates the full workflow and passes your arguments to each step. It captures errors and writes them into `logs/pipeline-*.log`.

Usage examples:

```bash
# Full pipeline for today (download, unzip, import)
./run.sh

# Full pipeline for a specific date
./run.sh --date 2026-02-16

# Run pipeline for a single source
./run.sh --source Telefaxnummer

# Use MySQL import method instead of PHP
./run.sh --import-method mysql

# Skip download (use cached zips)
./run.sh --skip-download

# Dry-run (no destructive operations)
./run.sh --dry-run --date 2026-02-16
```

## Running individual steps (advanced)

If you want to run individual steps directly you can call the scripts in the root folder. This is useful for debugging or re-running a single step.

```bash
# Download only (writes zips to ./data/YYYY-MM-DD)
./cvr-download-data.sh

# Download specific source
./cvr-download-data.sh --source Telefaxnummer

# Unzip only (reads zips from ./data/YYYY-MM-DD and extracts to ./data/YYYY-MM-DD/unzipped)
./cvr-unzip-data.sh

# Unzip from specific date
./cvr-unzip-data.sh --date 2026-02-16

# Import using MySQL LOAD DATA
./cvr-import-mysql.sh

# Import using PHP/mysqli
./cvr-import-php.sh

# Import single source
./cvr-import-mysql.sh --source Telefaxnummer
```

Important: the runner (`run.sh`) is the recommended way to run everything because it collects logs and error output and will continue running remaining steps even if one fails.

## Configuration

All scripts read configuration from `cvr.conf` (in this folder) and support overriding via environment variables prefixed with `CVR_`.

Key variables (examples):

- `CVR_API_KEY` — your API key (required for download)
- `CVR_API_BASE_URL` — API base URL (required for download)
- `CVR_DATA_DIR` — base data directory (default `./data`)
- `CVR_LOG_DIR` — logs directory (default `./logs`)
- `CVR_DB_HOST` — database host
- `CVR_DB_PORT` — database port
- `CVR_DB_NAME` — database name
- `CVR_DB_USER` — database user
- `CVR_DB_PASS` — database password
- `CVR_VERBOSE` — enable verbose output

## Logs

- Pipeline runner log: `logs/pipeline-*.log`
- Download step log: `logs/download-*.log`
- Unzip step log: `logs/unzip-*.log`
- Import step logs: `logs/import-mysql-*.log` or `logs/import-php-*.log`

## Overrides (column type customizations)

You can customize column types for specific tables so not every column must be created as TEXT.\
Create a small `.conf` file per table under `overrides/`.

File name candidates:
- `_cvr_import_telefaxnummer.conf` (full table name)
- `telefaxnummer.conf` (short name)

File format (simple key=value lines):
```
# sanitized_column_name = SQL type fragment
telefaxnummer=VARCHAR(20) NULL
oprettet_dato=DATE NULL
antal_ansatte=INT NULL
```

If you want to explicitly skip reading overrides set the `--no-overrides` flag when calling the import scripts or the pipeline.

Example: run pipeline but skip overrides

```bash
# Run full pipeline skipping overrides
./run.sh --no-overrides

# Run only import step with no overrides
./cvr-import-mysql.sh --no-overrides --source Telefaxnummer
```


## Architecture

The structure is:

```
cvrimporter/
├── lib/                    (Reusable libraries)
│   ├── common.sh           (Shared utilities)
│   ├── download.sh         (Download functions)
│   ├── unzip.sh            (Unzip functions)
│   ├── import.sh           (Common import logic)
│   ├── import-mysql.sh     (MySQL import)
│   └── import-php.sh       (PHP import)
│
├── cvr-download-data.sh    (Download script)
├── cvr-unzip-data.sh       (Unzip script)
├── cvr-import-mysql.sh     (MySQL import script)
├── cvr-import-php.sh       (PHP import script)
│
├── run.sh                  (Pipeline runner)
├── cvr.conf                (Configuration)
└── README.md               (This file)
```

## Running from the repository root

If you want to run the pipeline from a higher-level folder:

```bash
cd scripts/cvrimport
./run.sh --date 2026-02-16 --import-method mysql
```

## Notes

- Keep `run.sh` and `README.md` at the repository path as the canonical entry point.
- Main scripts (cvr-*.sh) are located in the root folder for easy access.
- Reusable library modules are located in `lib/` subfolder for code organization.
- The pipeline maintains full backward compatibility with previous versions.
