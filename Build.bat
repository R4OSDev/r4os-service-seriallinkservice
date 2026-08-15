@echo off
setlocal EnableExtensions DisableDelayedExpansion

for %%I in ("%~dp0.") do set "R4OS_MODULE_ROOT=%%~fI"
set "R4OS_SETTINGS=%R4OS_MODULE_ROOT%\Settings.R4S"

if not exist "%R4OS_SETTINGS%" (
    echo ERROR: Settings file not found: "%R4OS_SETTINGS%"
    exit /b 1
)

set "R4OS_ARTIFACTS_SETTING="
set "R4OS_CONTRACT_SETTING="
set "R4OS_DEVKIT_SETTING="
set "R4OS_LIBRARIES_SETTING="
set "R4OS_SDK_SETTING="
set "R4OS_ZIG_SETTING="

for /f "usebackq tokens=1,* delims==" %%A in ("%R4OS_SETTINGS%") do (
    if /i "%%A"=="ARTIFACTS_ROOT" set "R4OS_ARTIFACTS_SETTING=%%B"
    if /i "%%A"=="CONTRACT_ROOT" set "R4OS_CONTRACT_SETTING=%%B"
    if /i "%%A"=="DEVKIT_ROOT" set "R4OS_DEVKIT_SETTING=%%B"
    if /i "%%A"=="LIBRARIES_ROOT" set "R4OS_LIBRARIES_SETTING=%%B"
    if /i "%%A"=="SDK_ROOT" set "R4OS_SDK_SETTING=%%B"
    if /i "%%A"=="ZIG_ROOT" set "R4OS_ZIG_SETTING=%%B"
)

for %%K in (ARTIFACTS CONTRACT DEVKIT SDK ZIG) do if not defined R4OS_%%K_SETTING (
    echo ERROR: %%K_ROOT is missing in "%R4OS_SETTINGS%".
    exit /b 1
)

pushd "%R4OS_MODULE_ROOT%" >nul || exit /b 1
for %%I in ("%R4OS_ARTIFACTS_SETTING%") do set "R4OS_ARTIFACTS_ROOT=%%~fI"
for %%I in ("%R4OS_CONTRACT_SETTING%") do set "R4OS_CONTRACT_ROOT=%%~fI"
for %%I in ("%R4OS_DEVKIT_SETTING%") do set "R4OS_DEVKIT_ROOT=%%~fI"
if defined R4OS_LIBRARIES_SETTING for %%I in ("%R4OS_LIBRARIES_SETTING%") do set "R4OS_LIBRARIES_ROOT=%%~fI"
for %%I in ("%R4OS_SDK_SETTING%") do set "R4OS_SDK_ROOT=%%~fI"
popd

pushd "%R4OS_DEVKIT_ROOT%" >nul || (
    echo ERROR: DevKit root not found: "%R4OS_DEVKIT_ROOT%"
    exit /b 1
)
for %%I in ("%R4OS_ZIG_SETTING%") do set "R4OS_ZIG_ROOT=%%~fI"
popd

if not exist "%R4OS_CONTRACT_ROOT%\build.zig.zon" (
    echo ERROR: Contract repository not found: "%R4OS_CONTRACT_ROOT%"
    exit /b 1
)
if not exist "%R4OS_SDK_ROOT%\build.zig.zon" (
    echo ERROR: SDK repository not found: "%R4OS_SDK_ROOT%"
    exit /b 1
)
if defined R4OS_LIBRARIES_ROOT if not exist "%R4OS_LIBRARIES_ROOT%\build.zig.zon" (
    echo ERROR: Libraries repository not found: "%R4OS_LIBRARIES_ROOT%"
    exit /b 1
)

set "R4OS_ZIG_EXE=%R4OS_ZIG_ROOT%\zig.exe"
if not exist "%R4OS_ZIG_EXE%" (
    echo ERROR: Zig executable not found: "%R4OS_ZIG_EXE%"
    exit /b 1
)

if not exist "%R4OS_ARTIFACTS_ROOT%\" mkdir "%R4OS_ARTIFACTS_ROOT%"
if errorlevel 1 (
    echo ERROR: Artifacts root could not be created: "%R4OS_ARTIFACTS_ROOT%"
    exit /b 1
)

set "R4OS_FORKS=--fork="%R4OS_SDK_ROOT%" --fork="%R4OS_CONTRACT_ROOT%""
if defined R4OS_LIBRARIES_ROOT set "R4OS_FORKS=%R4OS_FORKS% --fork="%R4OS_LIBRARIES_ROOT%""

pushd "%R4OS_MODULE_ROOT%" >nul || exit /b 1
"%R4OS_ZIG_EXE%" build --prefix "%R4OS_ARTIFACTS_ROOT%" %R4OS_FORKS% %*
set "R4OS_EXIT_CODE=%ERRORLEVEL%"
popd

exit /b %R4OS_EXIT_CODE%
