@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem =========================================================================
rem  flash.bat - xingxing (Xingzhi CUBE 1.54 TFT WiFi, star robot)
rem  Build and flash (with erase-flash for a clean state).
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

set "EXPECTED_BOARD=CONFIG_BOARD_TYPE_XINGZHI_CUBE_1_54TFT_WIFI=y"
set "EXPECTED_UI=CONFIG_ADHD_KIDS_UI=y"

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

echo ============================================
echo   XIAOZHI star robot firmware
echo   Project: xiaozhi-esp32-2.2.4
echo   Board:  Xingzhi CUBE 1.54 TFT WiFi
echo ============================================
echo.
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

rem --- Regenerate generated language header before CMake scans sources ---
rem lang_config.h is git-ignored, so another checkout may have a stale copy
rem that does not include newly added OGG constants such as OGG_HINT_TRY_SHAKE.
echo [%SCRIPT_NAME%] Regenerating language config: zh-CN
python "%PROJECT_DIR%\scripts\gen_lang.py" --language zh-CN --output "%PROJECT_DIR%\main\assets\lang_config.h"
if errorlevel 1 exit /b 1
echo.

rem --- Ensure target is ESP32-S3 ---
if not exist "%CD%\sdkconfig" (
  echo [%SCRIPT_NAME%] sdkconfig missing, running fullclean and set-target esp32s3...
  idf.py fullclean
  if errorlevel 1 exit /b 1
  idf.py set-target esp32s3
  if errorlevel 1 exit /b 1
  echo.
)

rem --- Check board config ---
findstr /x /c:"%EXPECTED_BOARD%" "%CD%\sdkconfig" >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] WARNING: Wrong board in sdkconfig, auto-cleaning...
  idf.py fullclean
  if errorlevel 1 exit /b 1
  del /q "%CD%\sdkconfig" 2>nul
  idf.py set-target esp32s3
  if errorlevel 1 exit /b 1
  echo.
)

rem --- Run reconfigure ---
echo [%SCRIPT_NAME%] Running: idf.py reconfigure
idf.py reconfigure
if errorlevel 1 exit /b 1
echo.

rem --- Verify board ---
findstr /x /c:"%EXPECTED_BOARD%" "%CD%\sdkconfig" >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] ERROR: sdkconfig still has the wrong board after reconfigure.
  echo [%SCRIPT_NAME%] Required: %EXPECTED_BOARD%
  exit /b 1
)

rem --- Verify ADHD kids UI ---
findstr /x /c:"%EXPECTED_UI%" "%CD%\sdkconfig" >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] ERROR: CONFIG_ADHD_KIDS_UI is missing after reconfigure.
  echo [%SCRIPT_NAME%] Check sdkconfig.defaults and Kconfig.projbuild.
  exit /b 1
)

rem --- Build, erase-flash, and flash ---
echo [%SCRIPT_NAME%] Running: idf.py %IDF_ARGS% build erase-flash flash
echo [%SCRIPT_NAME%] Erasing flash avoids booting stale 1.47B/factory/OTA images.
idf.py %IDF_ARGS% build erase-flash flash
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
