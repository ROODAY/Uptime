@echo off
REM Script to build Android APK and Windows executable, prepare for GitHub release
REM Reads version from pubspec.yaml automatically
REM Note: For better functionality, use build_and_release.ps1 instead

setlocal enabledelayedexpansion

echo Reading version from pubspec.yaml...

REM Read version from pubspec.yaml (simple grep-like approach)
for /f "tokens=2" %%a in ('findstr /r /c:"^version:" pubspec.yaml') do set VERSION=%%a

if "%VERSION%"=="" (
    echo ERROR: Could not find version in pubspec.yaml
    exit /b 1
)

echo Found version: %VERSION%

REM Create git tag (v prefix)
set TAG=v%VERSION%

REM Create output directory
if not exist releases mkdir releases

set ANDROID_SUCCESS=0
set WINDOWS_SUCCESS=0

REM Build Android APK
echo.
echo Building Android APK for version %VERSION%...
flutter build apk --release

if not errorlevel 1 (
    set APK_PATH=build\app\outputs\flutter-apk\app-release.apk
    set OUTPUT_APK=releases\uptime-%VERSION%.apk
    
    if exist "%APK_PATH%" (
        copy "%APK_PATH%" "%OUTPUT_APK%" >nul
        echo ✓ APK built successfully: %OUTPUT_APK%
        set ANDROID_SUCCESS=1
    ) else (
        echo WARNING: APK not found at %APK_PATH%
    )
) else (
    echo WARNING: Android APK build failed!
)

REM Build Windows executable
echo.
echo Building Windows executable for version %VERSION%...
flutter build windows --release

if not errorlevel 1 (
    set WINDOWS_BUILD_PATH=build\windows\x64\runner\Release
    set OUTPUT_ZIP=releases\uptime-windows-%VERSION%.zip
    set TEMP_DIR=releases\temp-windows-%VERSION%
    
    if exist "%WINDOWS_BUILD_PATH%" (
        REM Create temp directory and copy files
        if exist "%TEMP_DIR%" rmdir /s /q "%TEMP_DIR%"
        mkdir "%TEMP_DIR%"
        xcopy "%WINDOWS_BUILD_PATH%\*" "%TEMP_DIR%\" /E /I /Y >nul
        
        REM Create ZIP (requires PowerShell or 7-Zip)
        REM Note: This uses PowerShell's Compress-Archive, which requires PowerShell 5.0+
        powershell -Command "Compress-Archive -Path '%TEMP_DIR%\*' -DestinationPath '%OUTPUT_ZIP%' -Force" 2>nul
        
        REM Clean up temp directory
        rmdir /s /q "%TEMP_DIR%"
        
        if exist "%OUTPUT_ZIP%" (
            echo ✓ Windows build packaged successfully: %OUTPUT_ZIP%
            echo   Note: Extract the ZIP and run uptime.exe
            set WINDOWS_SUCCESS=1
        ) else (
            echo WARNING: Failed to create ZIP file. Make sure PowerShell is available.
        )
    ) else (
        echo WARNING: Windows build not found at %WINDOWS_BUILD_PATH%
    )
) else (
    echo WARNING: Windows build failed!
)

REM Summary
echo.
echo ============================================================
echo Build Summary:
echo ============================================================
if %ANDROID_SUCCESS%==1 (
    echo ✓ Android: releases\uptime-%VERSION%.apk
) else (
    echo ✗ Android: Build failed or skipped
)
if %WINDOWS_SUCCESS%==1 (
    echo ✓ Windows: releases\uptime-windows-%VERSION%.zip
) else (
    echo ✗ Windows: Build failed or skipped
)

if %ANDROID_SUCCESS%==0 if %WINDOWS_SUCCESS%==0 (
    echo.
    echo ERROR: No builds succeeded!
    exit /b 1
)

echo.
echo ============================================================
echo Next steps:
echo ============================================================
echo.
echo 1. Create and push git tag:
echo    git tag %TAG%
echo    git push origin %TAG%
echo.
echo 2. Create GitHub release:
echo    https://github.com/ROODAY/SitStandTimer/releases/new
echo.
echo    Release details:
echo    - Tag: %TAG%
echo    - Title: Uptime %VERSION%
echo    - Description: Alpha release - testing phase
echo    - ☑ Mark as pre-release
if %ANDROID_SUCCESS%==1 (
    echo    - Upload: releases\uptime-%VERSION%.apk
)
if %WINDOWS_SUCCESS%==1 (
    echo    - Upload: releases\uptime-windows-%VERSION%.zip
)
echo.
echo 3. Share the release link with your testers!
echo.

endlocal
