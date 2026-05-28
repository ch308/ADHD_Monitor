@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem =========================================================================
rem  buildAndflash-xiaozhi.bat - ????? (xiaozhi-esp32-2.2.4)
rem  Board: Xingzhi CUBE 1.54 TFT WiFi (SPI ST7789 240x240, NOT 1.47B LCD_TEST)
rem
rem  Usage (from ADHD_Monitor repo root):
rem    buildAndflash-xiaozhi.bat
rem    buildAndflash-xiaozhi.bat -p COM5
rem    buildAndflash-xiaozhi.bat monitor
rem    buildAndflash-xiaozhi.bat monitor -p COM5
rem
rem  All paths are relative to this script (ADHD_Monitor repo root).
rem  Optional: esp_idf_path.txt (relative or absolute path to export.bat)
rem =========================================================================

set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
set "PROJECT_REL=xiaozhi-esp32-2.2.4"
set "PROJECT_DIR=%REPO_ROOT%\%PROJECT_REL%"
set "SCRIPT_NAME=buildAndflash-xiaozhi"

if not exist "%PROJECT_DIR%\CMakeLists.txt" (
  echo [%SCRIPT_NAME%] ERROR: project not found:
  echo   %PROJECT_REL%  ^(from repo root^)
  echo   %PROJECT_DIR%
  exit /b 1
)

echo.
echo ============================================
echo   XIAOZHI star robot firmware
echo   Project: %PROJECT_REL%
echo   Board:  Xingzhi CUBE 1.54 TFT WiFi
echo   Log tag: XINGZHI_CUBE / Application (NOT LCD_TEST)
echo ============================================
echo.

set "MODE=flash"
if /i "%~1"=="monitor" (
  set "MODE=monitor"
  shift
)
if /i "%~1"=="build" (
  set "MODE=build"
  shift
)
if /i "%~1"=="flash" (
  set "MODE=flash"
  shift
)
if /i "%~1"=="cleanflash" (
  set "MODE=cleanflash"
  shift
)

set "DEFAULT_PORT=COM5"
set "IDF_ARGS="
:collect_args
if "%~1"=="" goto args_done
set "IDF_ARGS=%IDF_ARGS% %~1"
shift
goto :collect_args
:args_done
set "HAS_PORT="
for %%A in (%IDF_ARGS%) do (
  if /i "%%~A"=="-p" set "HAS_PORT=1"
  if /i "%%~A"=="--port" set "HAS_PORT=1"
)
if /i not "%MODE%"=="build" if not defined HAS_PORT set "IDF_ARGS=-p %DEFAULT_PORT% %IDF_ARGS%"

cd /d "%PROJECT_DIR%"
if errorlevel 1 exit /b 1

call "%REPO_ROOT%\_idf_export.bat"
if errorlevel 1 exit /b 1

echo [%SCRIPT_NAME%] PROJECT_DIR=%CD%
echo [%SCRIPT_NAME%] IDF_PATH=%IDF_PATH%
echo [%SCRIPT_NAME%] Mode=%MODE%  Extra args: %IDF_ARGS%
echo.

if /i "%MODE%"=="monitor" (
  echo [%SCRIPT_NAME%] Starting serial monitor...
  echo [%SCRIPT_NAME%] Expect log: SKU=xingzhi-cube-1.54tft-wifi
  idf.py %IDF_ARGS% monitor
  exit /b %ERRORLEVEL%
)

set "EXPECTED_BOARD=CONFIG_BOARD_TYPE_XINGZHI_CUBE_1_54TFT_WIFI=y"

if not exist "%CD%\sdkconfig" (
  echo [%SCRIPT_NAME%] sdkconfig missing, running fullclean and set-target esp32s3...
  idf.py fullclean
  if errorlevel 1 exit /b 1
  idf.py set-target esp32s3
  if errorlevel 1 exit /b 1
  echo.
)

findstr /x /c:"%EXPECTED_BOARD%" "%CD%\sdkconfig" >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] WARNING: Wrong board in sdkconfig, auto-cleaning and reconfiguring...
  idf.py fullclean
  if errorlevel 1 exit /b 1
  del /q "%CD%\sdkconfig"
  idf.py set-target esp32s3
  if errorlevel 1 exit /b 1
  idf.py reconfigure
  if errorlevel 1 exit /b 1
  echo.
)

findstr /x /c:"CONFIG_ADHD_KIDS_UI=y" "%CD%\sdkconfig" >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] WARNING: CONFIG_ADHD_KIDS_UI is not enabled in sdkconfig.
  echo [%SCRIPT_NAME%] Run: idf.py reconfigure   or add CONFIG_ADHD_KIDS_UI=y
  echo.
)

echo [%SCRIPT_NAME%] Running: idf.py reconfigure
idf.py reconfigure
if errorlevel 1 exit /b 1
echo.

findstr /x /c:"%EXPECTED_BOARD%" "%CD%\sdkconfig" >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] ERROR: sdkconfig still has the wrong board after reconfigure.
  echo [%SCRIPT_NAME%] Required: %EXPECTED_BOARD%
  exit /b 1
)

findstr /x /c:"CONFIG_ADHD_KIDS_UI=y" "%CD%\sdkconfig" >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] ERROR: CONFIG_ADHD_KIDS_UI is missing after reconfigure.
  echo [%SCRIPT_NAME%] Check sdkconfig.defaults and Kconfig.projbuild.
  exit /b 1
)

if /i "%MODE%"=="build" (
  echo [%SCRIPT_NAME%] Running: idf.py build
  idf.py build
  exit /b %ERRORLEVEL%
)

if /i "%MODE%"=="cleanflash" (
  echo [%SCRIPT_NAME%] Running: idf.py %IDF_ARGS% build erase-flash flash
  idf.py %IDF_ARGS% build erase-flash flash
  if errorlevel 1 exit /b 1
  goto :success
)

if defined NO_ERASE_FLASH (
  echo [%SCRIPT_NAME%] Running: idf.py %IDF_ARGS% build flash
  idf.py %IDF_ARGS% build flash
) else (
  echo [%SCRIPT_NAME%] Running: idf.py %IDF_ARGS% build erase-flash flash
  echo [%SCRIPT_NAME%] Erasing flash avoids booting stale 1.47B/factory/OTA images.
  echo [%SCRIPT_NAME%] Set NO_ERASE_FLASH=1 to skip this after the board is stable.
  idf.py %IDF_ARGS% build erase-flash flash
)
if errorlevel 1 exit /b 1

:success
echo.
echo [%SCRIPT_NAME%] SUCCESS: xiaozhi build and flash done.
echo [%SCRIPT_NAME%] Monitor: buildAndflash-xiaozhi.bat monitor %IDF_ARGS%
echo [%SCRIPT_NAME%] Do NOT use buildAndflash-lcd147.bat on the star robot board.
echo.

endlocal
exit /b 0
