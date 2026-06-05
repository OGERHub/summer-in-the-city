@echo off
set SCRIPT_DIR=%~dp0
if "%QGIS_BIN%"=="" set QGIS_BIN=qgis
"%QGIS_BIN%" --code "%SCRIPT_DIR%create_qgis_project_koeln.py"
