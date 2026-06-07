@echo off
setlocal EnableExtensions

REM ============================================================
REM run_create_qgis_project.bat
REM ============================================================
REM Starts the PyQGIS project/layout builder:
REM
REM   scripts\create_qgis_project.py
REM
REM The Python script reads:
REM   QGIS_SCRIPT_DIR
REM   PROJECT_ROOT
REM
REM because QGIS --code does not define __file__.
REM ============================================================

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "PROJECT_ROOT=%%~fI"

set "QGIS_SCRIPT=%SCRIPT_DIR%create_qgis_project.py"

if not exist "%QGIS_SCRIPT%" (
  echo ERROR: QGIS Python script not found: %QGIS_SCRIPT% 1>&2
  exit /b 1
)

REM ------------------------------------------------------------
REM QGIS executable
REM ------------------------------------------------------------
REM You can set QGIS_BIN manually before running, for example:
REM   set QGIS_BIN=C:\Program Files\QGIS 3.34.4\bin\qgis-bin.exe
REM   set QGIS_BIN=C:\OSGeo4W\bin\qgis-ltr-bin.exe
REM ------------------------------------------------------------

if not defined QGIS_BIN (
  if exist "%ProgramFiles%\QGIS 3.34.4\bin\qgis-bin.exe" set "QGIS_BIN=%ProgramFiles%\QGIS 3.34.4\bin\qgis-bin.exe"
)

if not defined QGIS_BIN (
  if exist "%ProgramFiles%\QGIS 3.34.4\bin\qgis-ltr-bin.exe" set "QGIS_BIN=%ProgramFiles%\QGIS 3.34.4\bin\qgis-ltr-bin.exe"
)

if not defined QGIS_BIN (
  if exist "C:\OSGeo4W\bin\qgis-ltr-bin.exe" set "QGIS_BIN=C:\OSGeo4W\bin\qgis-ltr-bin.exe"
)

if not defined QGIS_BIN (
  if exist "C:\OSGeo4W\bin\qgis-bin.exe" set "QGIS_BIN=C:\OSGeo4W\bin\qgis-bin.exe"
)

if not defined QGIS_BIN (
  echo ERROR: QGIS_BIN is not set and no common QGIS installation was found. 1>&2
  echo Set QGIS_BIN manually, for example: 1>&2
  echo   set QGIS_BIN=C:\Program Files\QGIS 3.34.4\bin\qgis-bin.exe 1>&2
  exit /b 1
)

if not exist "%QGIS_BIN%" (
  echo ERROR: QGIS executable not found: %QGIS_BIN% 1>&2
  exit /b 1
)

REM Avoid leaking external Python settings into QGIS.
set "PYTHONHOME="
set "PYTHONPATH="
set "VIRTUAL_ENV="
set "RETICULATE_PYTHON="
set "RETICULATE_PYTHON_FALLBACK="
set "PYTHONNOUSERSITE=1"

REM These are consumed by create_qgis_project.py.
set "QGIS_SCRIPT_DIR=%SCRIPT_DIR%"
set "PROJECT_ROOT=%PROJECT_ROOT%"

echo Running QGIS project/export script:
echo   QGIS:   %QGIS_BIN%
echo   Script: %QGIS_SCRIPT%
echo   PROJECT_ROOT: %PROJECT_ROOT%
echo   QGIS_SCRIPT_DIR: %QGIS_SCRIPT_DIR%

"%QGIS_BIN%" --noplugins --code "%QGIS_SCRIPT%"

exit /b %ERRORLEVEL%
