#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QGIS_BIN="${QGIS_BIN:-qgis}"
"$QGIS_BIN" --code "$SCRIPT_DIR/create_qgis_project_koeln.py"
