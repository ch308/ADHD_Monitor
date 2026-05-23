@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem =========================================================================
rem  monitor.bat - ESP32-S3-LCD-1.47B serial monitor
rem
rem  Usage:
rem    monitor.bat
rem    monitor.bat -p COM5
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
  echo [monitor.bat] ERROR: project not found:
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
  echo [monitor.bat] ERROR: Could not find ESP-IDF export.bat.
  echo.
  echo Create one of:
  echo   %PROJECT_DIR%esp_idf_path.txt
  echo   %REPO_ROOT%\esp_idf_path.txt
  echo with one line: full path to export.bat
  echo Or set ESP_IDF_EXPORT_BAT / IDF_PATH.
  goto :fail
)

if not exist "%EXPORT_BAT%" (
  echo [monitor.bat] ERROR: export.bat not found:
  echo   %EXPORT_BAT%
  goto :fail
)

if defined IDF_TOOLS_PATH if not defined KEEP_IDF_TOOLS_PATH (
  echo [monitor.bat] Clearing IDF_TOOLS_PATH=%IDF_TOOLS_PATH%
  set "IDF_TOOLS_PATH="
)

echo [monitor.bat] Using: %EXPORT_BAT%
call "%EXPORT_BAT%"
if errorlevel 1 goto :fail

where idf.py >nul 2>&1
if errorlevel 1 (
  echo [monitor.bat] ERROR: idf.py not on PATH after export.bat
  goto :fail
)

echo [monitor.bat] PROJECT_DIR=%CD%
echo [monitor.bat] IDF_PATH=%IDF_PATH%
echo [monitor.bat] Extra idf.py args: %*
echo.

idf.py %* monitor
if errorlevel 1 goto :fail

endlocal
exit /b 0

:fail
echo.
echo [monitor.bat] FAILED.
echo.
pause
endlocal
exit /b 1
