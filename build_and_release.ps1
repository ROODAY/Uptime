# PowerShell script to build Android APK and Windows executable, prepare for GitHub release
# Reads version from pubspec.yaml automatically

$ErrorActionPreference = "Stop"

Write-Host "Reading version from pubspec.yaml..." -ForegroundColor Cyan

# Read version from pubspec.yaml
$pubspecContent = Get-Content "pubspec.yaml" -Raw
if ($pubspecContent -match "version:\s*([^\s]+)") {
    $version = $matches[1].Trim()
    Write-Host "Found version: $version" -ForegroundColor Green
} else {
    Write-Host "ERROR: Could not find version in pubspec.yaml" -ForegroundColor Red
    exit 1
}

# Create git tag (v prefix)
$tag = "v$version"

# Create output directory
if (-not (Test-Path "releases")) {
    New-Item -ItemType Directory -Path "releases" | Out-Null
}

$buildSuccess = @{
    Android = $false
    Windows = $false
}

# Build Android APK
Write-Host "`nBuilding Android APK for version $version..." -ForegroundColor Cyan
flutter build apk --release

if ($LASTEXITCODE -eq 0) {
    $apkPath = "build\app\outputs\flutter-apk\app-release.apk"
    $outputApk = "releases\uptime-$version.apk"
    
    if (Test-Path $apkPath) {
        Copy-Item $apkPath $outputApk -Force
        $fileSize = (Get-Item $outputApk).Length / 1MB
        Write-Host "✓ APK built successfully: $outputApk" -ForegroundColor Green
        Write-Host "  File size: $([math]::Round($fileSize, 2)) MB" -ForegroundColor Gray
        $buildSuccess.Android = $true
    } else {
        Write-Host "WARNING: APK not found at $apkPath" -ForegroundColor Yellow
    }
} else {
    Write-Host "WARNING: Android APK build failed!" -ForegroundColor Yellow
}

# Build Windows executable
Write-Host "`nBuilding Windows executable for version $version..." -ForegroundColor Cyan
flutter build windows --release

if ($LASTEXITCODE -eq 0) {
    $windowsBuildPath = "build\windows\x64\runner\Release"
    $outputZip = "releases\uptime-windows-$version.zip"
    
    if (Test-Path $windowsBuildPath) {
        # Create a temporary directory for the Windows release
        $tempDir = "releases\temp-windows-$version"
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        
        # Copy all files from the Release folder
        Copy-Item "$windowsBuildPath\*" -Destination $tempDir -Recurse -Force
        
        # Create ZIP file
        if (Test-Path $outputZip) {
            Remove-Item $outputZip -Force
        }
        Compress-Archive -Path "$tempDir\*" -DestinationPath $outputZip -Force
        
        # Clean up temp directory
        Remove-Item $tempDir -Recurse -Force
        
        $fileSize = (Get-Item $outputZip).Length / 1MB
        Write-Host "✓ Windows build packaged successfully: $outputZip" -ForegroundColor Green
        Write-Host "  File size: $([math]::Round($fileSize, 2)) MB" -ForegroundColor Gray
        Write-Host "  Note: Extract the ZIP and run uptime.exe" -ForegroundColor Gray
        $buildSuccess.Windows = $true
    } else {
        Write-Host "WARNING: Windows build not found at $windowsBuildPath" -ForegroundColor Yellow
    }
} else {
    Write-Host "WARNING: Windows build failed!" -ForegroundColor Yellow
}

# Summary
Write-Host "`n" + ("="*60) -ForegroundColor Cyan
Write-Host "Build Summary:" -ForegroundColor Yellow
Write-Host ("="*60) -ForegroundColor Cyan
if ($buildSuccess.Android) {
    Write-Host "✓ Android: releases\uptime-$version.apk" -ForegroundColor Green
} else {
    Write-Host "✗ Android: Build failed or skipped" -ForegroundColor Red
}
if ($buildSuccess.Windows) {
    Write-Host "✓ Windows: releases\uptime-windows-$version.zip" -ForegroundColor Green
} else {
    Write-Host "✗ Windows: Build failed or skipped" -ForegroundColor Red
}

if (-not ($buildSuccess.Android -or $buildSuccess.Windows)) {
    Write-Host "`nERROR: No builds succeeded!" -ForegroundColor Red
    exit 1
}

Write-Host "`n" + ("="*60) -ForegroundColor Cyan
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host ("="*60) -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Create and push git tag:" -ForegroundColor White
Write-Host "   git tag $tag" -ForegroundColor Gray
Write-Host "   git push origin $tag" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Create GitHub release:" -ForegroundColor White
Write-Host "   https://github.com/ROODAY/SitStandTimer/releases/new" -ForegroundColor Blue
Write-Host ""
Write-Host "   Release details:" -ForegroundColor White
Write-Host "   - Tag: $tag" -ForegroundColor Gray
Write-Host "   - Title: Uptime $version" -ForegroundColor Gray
Write-Host "   - Description: Alpha release - testing phase" -ForegroundColor Gray
Write-Host "   - ☑ Mark as pre-release" -ForegroundColor Gray
if ($buildSuccess.Android) {
    Write-Host "   - Upload: releases\uptime-$version.apk" -ForegroundColor Gray
}
if ($buildSuccess.Windows) {
    Write-Host "   - Upload: releases\uptime-windows-$version.zip" -ForegroundColor Gray
}
Write-Host ""
Write-Host "3. Share the release link with your testers!" -ForegroundColor White
Write-Host ""
