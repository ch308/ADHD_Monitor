@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem =========================================================================
rem  flash.bat - ESP32-S3-LCD-1.47B (1.47 inch ST7789T, plush ball)
rem  Build and flash.
rem
rem  Usage:
rem    flash.bat
rem    flash.bat -p COM5
rem    flash.bat -j4 -p COM6
rem =========================================================================

set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"
set "SCRIPT_NAME=%~n0"
set "DEFAULT_PORT=COM5"

if not exist "%PROJECT_DIR%\CMakeLists.txt" (
  echo [%SCRIPT_NAME%] ERROR: project not found: %PROJECT_DIR%
  exit /b 1
)

cd /d "%PROJECT_DIR%"

rem --- Collect extra args and detect -p ---
set "HAS_PORT="
set "IDF_ARGS="
:collect_args
if "%~1"=="" goto args_done
set "IDF_ARGS=%IDF_ARGS% %~1"
if /i "%~1"=="-p" set "HAS_PORT=1"
if /i "%~1"=="--port" set "HAS_PORT=1"
shift
goto :collect_args
:args_done
if not defined HAS_PORT set "IDF_ARGS=-p %DEFAULT_PORT% %IDF_ARGS%"

rem --- Locate ESP-IDF export.bat ---
set "EXPORT_BAT="
if defined ESP_IDF_EXPORT_BAT call :try_path "%ESP_IDF_EXPORT_BAT%"
if not defined EXPORT_BAT if defined IDF_PATH call :try_path "%IDF_PATH%\export.bat"
if not defined EXPORT_BAT if exist "%PROJECT_DIR%\esp_idf_path.txt" (
  for /f "usebackq eol=# delims=" %%L in ("%PROJECT_DIR%\esp_idf_path.txt") do (
    if not defined EXPORT_BAT if not "%%L"=="" call :try_path "%%L"
  )
)
if not defined EXPORT_BAT if exist "%PROJECT_DIR%\..\esp_idf_path.txt" (
  for /f "usebackq eol=# delims=" %%L in ("%PROJECT_DIR%\..\esp_idf_path.txt") do (
    if not defined EXPORT_BAT if not "%%L"=="" call :try_path "%%L"
  )
)
if not defined EXPORT_BAT call :try_path "%USERPROFILE%\esp\esp-idf\export.bat"
if not defined EXPORT_BAT call :try_path "%USERPROFILE%\esp-idf\export.bat"
for %%D in (C D E F) do if not defined EXPORT_BAT if exist "%%D:\esp\" (
  for /f "delims=" %%V in ('dir /b /ad /o-n "%%D:\esp\v*" 2^>nul') do (
    call :try_path "%%D:\esp\%%V\esp-idf\export.bat"
  )
)
for %%D in (C D E F) do if not defined EXPORT_BAT if exist "%%D:\Espressif\frameworks\" (
  for /f "delims=" %%F in ('dir /b /ad /o-n "%%D:\Espressif\frameworks\esp-idf-v*" 2^>nul') do (
    call :try_path "%%D:\Espressif\frameworks\%%F\export.bat"
  )
)

if not defined EXPORT_BAT (
  echo [%SCRIPT_NAME%] ERROR: Could not find ESP-IDF export.bat.
  echo Set ESP_IDF_EXPORT_BAT or create esp_idf_path.txt with the path to export.bat.
  exit /b 1
)

rem --- Activate ESP-IDF ---
if defined IDF_TOOLS_PATH if not defined KEEP_IDF_TOOLS_PATH (
  echo [%SCRIPT_NAME%] Clearing IDF_TOOLS_PATH=%IDF_TOOLS_PATH%
  set "IDF_TOOLS_PATH="
)

echo [%SCRIPT_NAME%] PROJECT_DIR=%CD%
echo [%SCRIPT_NAME%] IDF: %EXPORT_BAT%
call "%EXPORT_BAT%"
if errorlevel 1 exit /b 1

where idf.py >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] ERROR: idf.py not on PATH after export.bat
  exit /b 1
)

echo [%SCRIPT_NAME%] IDF_PATH=%IDF_PATH%
echo [%SCRIPT_NAME%] Extra args: %IDF_ARGS%
echo.

rem --- Ensure target is ESP32-S3 ---
if not exist "%CD%\sdkconfig" (
  echo [%SCRIPT_NAME%] sdkconfig missing, setting target to esp32s3...
  idf.py fullclean
  if errorlevel 1 exit /b 1
  idf.py set-target esp32s3
  if errorlevel 1 exit /b 1
  echo.
)

rem --- Build and flash ---
echo [%SCRIPT_NAME%] Running: idf.py %IDF_ARGS% build flash
idf.py %IDF_ARGS% build flash
if errorlevel 1 (
  echo [%SCRIPT_NAME%] FAILED.
  endlocal & exit /b 1
)

echo [%SCRIPT_NAME%] SUCCESS: Build and flash completed.
echo [%SCRIPT_NAME%] To monitor: idf.py -p %DEFAULT_PORT% monitor
endlocal
exit /b 0

rem --- Helper: expand relative path and check existence ---
:try_path
if "%~1"=="" exit /b
set "TRY=%~1"
if "%TRY:~-1%"=="\" set "TRY=%TRY:~0,-1%"
if "%TRY:~-11%"=="export.bat" goto :tp_check
if exist "%TRY%\export.bat" set "TRY=%TRY%\export.bat"
:tp_check
if not "%TRY:~1,1%"==":" set "TRY=%PROJECT_DIR%\%TRY%"
if exist "%TRY%" set "EXPORT_BAT=%TRY%"
exit /b
