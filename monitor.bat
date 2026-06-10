@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem Monitor the xingxing star robot from the repository root.
set "SCRIPT_NAME=monitor"
set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
set "PROJECT_DIR=%REPO_ROOT%\xingxing"
set "DEFAULT_PORT=COM5"

set "HAS_PORT="
set "IDF_ARGS="
:collect_args
if "%~1"=="" goto args_done
set "IDF_ARGS=!IDF_ARGS! %~1"
if /i "%~1"=="-p" set "HAS_PORT=1"
if /i "%~1"=="--port" set "HAS_PORT=1"
shift
goto :collect_args
:args_done
if not defined HAS_PORT set "IDF_ARGS=-p %DEFAULT_PORT% %IDF_ARGS%"

call "%REPO_ROOT%\_idf_export.bat"
if errorlevel 1 exit /b 1

cd /d "%PROJECT_DIR%"
echo [monitor] Running: idf.py %IDF_ARGS% monitor
idf.py %IDF_ARGS% monitor
exit /b %ERRORLEVEL%
