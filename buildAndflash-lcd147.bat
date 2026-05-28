@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem =========================================================================
rem  buildAndflash-lcd147.bat - ADHD plush ball (ESP32-S3-LCD-1.47B)
rem  1.47 inch ST7789T board, different pins from Xingzhi CUBE 1.54.
rem
rem  Usage (from ADHD_Monitor repo root):
rem    buildAndflash-lcd147.bat
rem    buildAndflash-lcd147.bat -p COM5
rem    buildAndflash-lcd147.bat monitor
rem    buildAndflash-lcd147.bat monitor -p COM5
rem
rem  All paths are relative to this script (ADHD_Monitor repo root).
rem  Optional: esp_idf_path.txt (relative or absolute path to export.bat)
rem =========================================================================

set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
set "PROJECT_REL=ESP32-S3-LCD-1.47B"
set "PROJECT_DIR=%REPO_ROOT%\%PROJECT_REL%"
set "SCRIPT_NAME=buildAndflash-lcd147"

if not exist "%PROJECT_DIR%\CMakeLists.txt" (
  echo [%SCRIPT_NAME%] ERROR: project not found:
  echo   %PROJECT_REL%  (from repo root)
  echo   %PROJECT_DIR%
  exit /b 1
)

echo.
echo ============================================
echo   ESP32-S3-LCD-1.47B firmware (plush ball)
echo   Project: %PROJECT_REL%
echo   NOT for Xingzhi CUBE 1.54 star robot
echo ============================================
echo.

set "MODE=build"
if /i "%~1"=="monitor" (
  set "MODE=monitor"
  shift
)

cd /d "%PROJECT_DIR%"
if errorlevel 1 exit /b 1

call "%REPO_ROOT%_idf_export.bat"
if errorlevel 1 exit /b 1

echo [%SCRIPT_NAME%] PROJECT_DIR=%CD%
echo [%SCRIPT_NAME%] IDF_PATH=%IDF_PATH%
echo [%SCRIPT_NAME%] Mode=%MODE%  Extra args: %*
echo.

if /i "%MODE%"=="monitor" (
  echo [%SCRIPT_NAME%] Starting serial monitor...
  echo [%SCRIPT_NAME%] Expect project name: ESP32-S3-LCD-1.47B (not xiaozhi)
  idf.py monitor %*
  exit /b %ERRORLEVEL%
)

if not exist "%CD%\sdkconfig" (
  echo [%SCRIPT_NAME%] sdkconfig missing, running set-target esp32s3...
  idf.py set-target esp32s3
  if errorlevel 1 exit /b 1
  echo.
)

echo [%SCRIPT_NAME%] Running: idf.py %* build flash
idf.py %* build flash
if errorlevel 1 exit /b 1

echo.
echo [%SCRIPT_NAME%] SUCCESS: 1.47B build and flash done.
echo [%SCRIPT_NAME%] Monitor: buildAndflash-lcd147.bat monitor %*
echo [%SCRIPT_NAME%] Do NOT use buildAndflash-xiaozhi.bat on the 1.47B board.
echo.

endlocal
exit /b 0
