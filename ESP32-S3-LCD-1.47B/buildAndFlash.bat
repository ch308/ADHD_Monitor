@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem =========================================================================
rem  buildAndFlash.bat - ESP32-S3-LCD-1.47B build and flash
rem
rem  Usage:
rem    buildAndFlash.bat
rem    buildAndFlash.bat -p COM5
rem
rem  Optional config file:
rem    esp_idf_path.txt in this folder or repo root
rem    one line: full path to export.bat
rem =========================================================================

set "PROJECT_DIR=%~dp0"
set "REPO_ROOT=%PROJECT_DIR%.."

cd /d "%PROJECT_DIR%"
if errorlevel 1 goto :fail

if not exist "%PROJECT_DIR%CMakeLists.txt" (
  echo [buildAndFlash.bat] ERROR: project not found:
  echo   %PROJECT_DIR%
  goto :fail
)

set "EXPORT_BAT="
if defined ESP_IDF_EXPORT_BAT set "EXPORT_BAT=%ESP_IDF_EXPORT_BAT%"
if not defined EXPORT_BAT if defined IDF_PATH set "EXPORT_BAT=%IDF_PATH%\export.bat"

if not defined EXPORT_BAT if exist "%PROJECT_DIR%esp_idf_path.txt" (
  for /f "usebackq delims=" %%L in ("%PROJECT_DIR%esp_idf_path.txt") do (
    if not defined EXPORT_BAT set "EXPORT_BAT=%%L"
  )
)

if not defined EXPORT_BAT if exist "%REPO_ROOT%\esp_idf_path.txt" (
  for /f "usebackq delims=" %%L in ("%REPO_ROOT%\esp_idf_path.txt") do (
    if not defined EXPORT_BAT set "EXPORT_BAT=%%L"
  )
)

if not defined EXPORT_BAT (
  for %%D in (C D E F) do if exist "%%D:\Espressif\frameworks\" (
    for /f "delims=" %%F in ('dir /b /ad /o-n "%%D:\Espressif\frameworks\esp-idf-v*" 2^>nul') do (
      if not defined EXPORT_BAT if exist "%%D:\Espressif\frameworks\%%F\export.bat" set "EXPORT_BAT=%%D:\Espressif\frameworks\%%F\export.bat"
    )
  )
)

if not defined EXPORT_BAT if exist "%LOCALAPPDATA%\Espressif\frameworks\" (
  for /f "delims=" %%F in ('dir /b /ad /o-n "%LOCALAPPDATA%\Espressif\frameworks\esp-idf-v*" 2^>nul') do (
    if not defined EXPORT_BAT if exist "%LOCALAPPDATA%\Espressif\frameworks\%%F\export.bat" set "EXPORT_BAT=%LOCALAPPDATA%\Espressif\frameworks\%%F\export.bat"
  )
)

if not defined EXPORT_BAT if exist "%USERPROFILE%\esp\esp-idf\export.bat" set "EXPORT_BAT=%USERPROFILE%\esp\esp-idf\export.bat"
if not defined EXPORT_BAT if exist "%USERPROFILE%\esp-idf\export.bat" set "EXPORT_BAT=%USERPROFILE%\esp-idf\export.bat"

if not defined EXPORT_BAT (
  for %%D in (C D E F) do if exist "%%D:\esp\" (
    for /f "delims=" %%V in ('dir /b /ad /o-n "%%D:\esp\v*" 2^>nul') do (
      if not defined EXPORT_BAT if exist "%%D:\esp\%%V\esp-idf\export.bat" set "EXPORT_BAT=%%D:\esp\%%V\esp-idf\export.bat"
    )
  )
)

if not defined EXPORT_BAT (
  echo [buildAndFlash.bat] ERROR: Could not find ESP-IDF export.bat.
  echo.
  echo Create one of:
  echo   %PROJECT_DIR%esp_idf_path.txt
  echo   %REPO_ROOT%\esp_idf_path.txt
  echo with one line: full path to export.bat
  echo Or set ESP_IDF_EXPORT_BAT / IDF_PATH.
  goto :fail
)

if not exist "%EXPORT_BAT%" (
  echo [buildAndFlash.bat] ERROR: export.bat not found:
  echo   %EXPORT_BAT%
  goto :fail
)

if defined IDF_TOOLS_PATH if not defined KEEP_IDF_TOOLS_PATH (
  echo [buildAndFlash.bat] Clearing IDF_TOOLS_PATH=%IDF_TOOLS_PATH%
  set "IDF_TOOLS_PATH="
)

echo [buildAndFlash.bat] Using: %EXPORT_BAT%
call "%EXPORT_BAT%"
if errorlevel 1 goto :fail

where idf.py >nul 2>&1
if errorlevel 1 (
  echo [buildAndFlash.bat] ERROR: idf.py not on PATH after export.bat
  goto :fail
)

echo [buildAndFlash.bat] PROJECT_DIR=%CD%
echo [buildAndFlash.bat] IDF_PATH=%IDF_PATH%
echo [buildAndFlash.bat] Extra idf.py args: %*
echo.

if not exist "%CD%\sdkconfig" (
  echo [buildAndFlash.bat] sdkconfig not found, setting target to esp32s3...
  idf.py set-target esp32s3
  if errorlevel 1 goto :fail
  echo.
)

echo [buildAndFlash.bat] Running: idf.py %* build flash
idf.py %* build flash
if errorlevel 1 goto :fail

echo.
echo [buildAndFlash.bat] SUCCESS: build and flash completed.
echo [buildAndFlash.bat] To watch logs, run: monitor.bat %*
echo.
pause
endlocal
exit /b 0

:fail
echo.
echo [buildAndFlash.bat] FAILED.
echo.
pause
endlocal
exit /b 1
