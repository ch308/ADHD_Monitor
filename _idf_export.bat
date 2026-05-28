@echo off
rem =========================================================================
rem  _idf_export.bat - locate ESP-IDF export.bat and activate the environment
rem  Called by build/monitor scripts. Caller must set REPO_ROOT (repo root dir).
rem  Paths in esp_idf_path.txt may be relative to REPO_ROOT.
rem  ASCII-only (Windows CMD / GBK safe).
rem =========================================================================

if defined REPO_ROOT if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"

set "EXPORT_BAT="

if defined ESP_IDF_EXPORT_BAT (
  call :resolve_path "%ESP_IDF_EXPORT_BAT%"
  if defined EXPORT_BAT goto :activate
)

if not defined EXPORT_BAT if defined IDF_PATH (
  call :resolve_path "%IDF_PATH%\export.bat"
  if defined EXPORT_BAT goto :activate
)

if not defined EXPORT_BAT if exist "%REPO_ROOT%\esp_idf_path.txt" (
  for /f "usebackq eol=# tokens=* delims=" %%L in ("%REPO_ROOT%\esp_idf_path.txt") do (
    if not defined EXPORT_BAT if not "%%L"=="" call :resolve_path "%%L"
  )
)

rem Optional bundled IDF next to repo (copy or junction): ADHD_Monitor\esp-idf\export.bat
if not defined EXPORT_BAT call :resolve_path "esp-idf\export.bat"

rem Standard user-profile installs (auto-detect, not repo-specific)
if not defined EXPORT_BAT call :resolve_path "%USERPROFILE%\esp\esp-idf\export.bat"
if not defined EXPORT_BAT call :resolve_path "%USERPROFILE%\esp-idf\export.bat"

for %%D in (C D E F) do if not defined EXPORT_BAT if exist "%%D:\Espressif\frameworks\" (
  for /f "delims=" %%F in ('dir /b /ad /o-n "%%D:\Espressif\frameworks\esp-idf-v*" 2^>nul') do (
    call :resolve_path "%%D:\Espressif\frameworks\%%F\export.bat"
  )
)

if not defined EXPORT_BAT if exist "%LOCALAPPDATA%\Espressif\frameworks\" (
  for /f "delims=" %%F in ('dir /b /ad /o-n "%LOCALAPPDATA%\Espressif\frameworks\esp-idf-v*" 2^>nul') do (
    call :resolve_path "%LOCALAPPDATA%\Espressif\frameworks\%%F\export.bat"
  )
)

for %%D in (C D E F) do if not defined EXPORT_BAT if exist "%%D:\esp\" (
  for /f "delims=" %%V in ('dir /b /ad /o-n "%%D:\esp\v*" 2^>nul') do (
    call :resolve_path "%%D:\esp\%%V\esp-idf\export.bat"
  )
)

if not defined EXPORT_BAT (
  echo [%SCRIPT_NAME%] ERROR: Could not find ESP-IDF export.bat.
  echo.
  echo Create %REPO_ROOT%\esp_idf_path.txt with one line, for example:
  echo   esp-idf\export.bat
  echo   ..\..\esp\v6.0.1\esp-idf\export.bat
  echo Or set ESP_IDF_EXPORT_BAT before running the script.
  echo.
  exit /b 1
)

:activate
if not exist "%EXPORT_BAT%" (
  echo [%SCRIPT_NAME%] ERROR: export.bat not found:
  echo   %EXPORT_BAT%
  exit /b 1
)

if defined IDF_TOOLS_PATH if not defined KEEP_IDF_TOOLS_PATH (
  echo [%SCRIPT_NAME%] Clearing IDF_TOOLS_PATH=%IDF_TOOLS_PATH%
  set "IDF_TOOLS_PATH="
)

echo [%SCRIPT_NAME%] REPO_ROOT=%REPO_ROOT%
echo [%SCRIPT_NAME%] Using ESP-IDF: %EXPORT_BAT%
call "%EXPORT_BAT%"
if errorlevel 1 exit /b 1

where idf.py >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] ERROR: idf.py not on PATH after export.bat
  exit /b 1
)

exit /b 0

rem %~1 = path (absolute or relative to REPO_ROOT)
:resolve_path
if "%~1"=="" exit /b 0
if exist "%EXPORT_BAT%" exit /b 0
set "TRY_PATH=%~1"
if "%TRY_PATH:~-1%"=="\" set "TRY_PATH=%TRY_PATH:~0,-1%"
if "%TRY_PATH:~-11%"=="export.bat" goto :rp_have_name
if exist "%TRY_PATH%\export.bat" set "TRY_PATH=%TRY_PATH%\export.bat"
:rp_have_name
if not "%TRY_PATH:~1,1%"==":" set "TRY_PATH=%REPO_ROOT%\%TRY_PATH%"
if exist "%TRY_PATH%" set "EXPORT_BAT=%TRY_PATH%"
exit /b 0
