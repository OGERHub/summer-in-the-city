#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Explicit system QGIS. Override only if needed:
#   QGIS_BIN=/path/to/qgis scripts/run_create_qgis_project_koeln.sh
QGIS_BIN="${QGIS_BIN:-/usr/bin/qgis}"

if [ ! -x "$QGIS_BIN" ]; then
  echo "ERROR: QGIS executable not found or not executable: $QGIS_BIN" >&2
  exit 1
fi

QGIS_SCRIPT="$SCRIPT_DIR/create_qgis_project.py"

if [ ! -f "$QGIS_SCRIPT" ]; then
  echo "ERROR: QGIS Python script not found: $QGIS_SCRIPT" >&2
  exit 1
fi

# QGIS 3.34 from apt needs the QGIS Python path and Debian dist-packages.
# This prevents reticulate / project venv paths from breaking PyQGIS/SIP.
export PYTHONNOUSERSITE=1
export PYTHONPATH="/usr/share/qgis/python:/usr/lib/python3/dist-packages"

unset PYTHONHOME
unset VIRTUAL_ENV
unset RETICULATE_PYTHON
unset RETICULATE_PYTHON_FALLBACK

# Keep normal system paths, remove project venv paths if present.
CLEAN_PATH="$(
  printf '%s' "$PATH" |
    tr ':' '\n' |
    grep -v '/\.venv' |
    awk 'NF' |
    paste -sd ':' -
)"

export PATH="$CLEAN_PATH"

echo "Running QGIS project/export script:"
echo "  QGIS:   $QGIS_BIN"
echo "  Script: $QGIS_SCRIPT"
echo "  PYTHONPATH: $PYTHONPATH"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export QGIS_SCRIPT_DIR="$SCRIPT_DIR"
export PROJECT_ROOT="$PROJECT_ROOT"

echo "  PROJECT_ROOT: $PROJECT_ROOT"
echo "  QGIS_SCRIPT_DIR: $QGIS_SCRIPT_DIR"

"$QGIS_BIN" --noplugins --code "$QGIS_SCRIPT"
