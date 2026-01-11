#!/bin/bash
# Script to build Android APK and Windows executable, prepare for GitHub release
# Reads version from pubspec.yaml automatically
# Note: Windows builds require running on Windows. This script will attempt both.

set -e

echo "Reading version from pubspec.yaml..."

# Read version from pubspec.yaml
VERSION=$(grep -E "^version:" pubspec.yaml | sed -E 's/version:[[:space:]]*//' | tr -d '[:space:]')

if [ -z "$VERSION" ]; then
    echo "ERROR: Could not find version in pubspec.yaml"
    exit 1
fi

echo "Found version: $VERSION"

# Create git tag (v prefix)
TAG="v$VERSION"

# Create output directory
mkdir -p releases

ANDROID_SUCCESS=0
WINDOWS_SUCCESS=0

# Build Android APK
echo ""
echo "Building Android APK for version $VERSION..."
if flutter build apk --release; then
    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
    OUTPUT_APK="releases/uptime-${VERSION}.apk"
    
    if [ -f "$APK_PATH" ]; then
        cp "$APK_PATH" "$OUTPUT_APK"
        FILE_SIZE=$(du -h "$OUTPUT_APK" | cut -f1)
        echo "✓ APK built successfully: $OUTPUT_APK"
        echo "  File size: $FILE_SIZE"
        ANDROID_SUCCESS=1
    else
        echo "WARNING: APK not found at $APK_PATH"
    fi
else
    echo "WARNING: Android APK build failed!"
fi

# Build Windows executable (only works on Windows)
echo ""
echo "Building Windows executable for version $VERSION..."
if flutter build windows --release 2>/dev/null; then
    WINDOWS_BUILD_PATH="build/windows/x64/runner/Release"
    OUTPUT_ZIP="releases/uptime-windows-${VERSION}.zip"
    TEMP_DIR="releases/temp-windows-${VERSION}"
    
    if [ -d "$WINDOWS_BUILD_PATH" ]; then
        # Create temp directory and copy files
        rm -rf "$TEMP_DIR"
        mkdir -p "$TEMP_DIR"
        cp -r "$WINDOWS_BUILD_PATH"/* "$TEMP_DIR/"
        
        # Create ZIP file
        cd "$TEMP_DIR"
        zip -r "../uptime-windows-${VERSION}.zip" . >/dev/null 2>&1 || {
            # Fallback: try using tar if zip is not available
            cd ..
            tar -czf "uptime-windows-${VERSION}.tar.gz" -C "$TEMP_DIR" . 2>/dev/null || {
                echo "WARNING: Failed to create archive. Please manually zip the contents of $WINDOWS_BUILD_PATH"
                rm -rf "$TEMP_DIR"
                exit 0
            }
            OUTPUT_ZIP="releases/uptime-windows-${VERSION}.tar.gz"
        }
        cd - >/dev/null
        
        # Clean up temp directory
        rm -rf "$TEMP_DIR"
        
        if [ -f "releases/uptime-windows-${VERSION}.zip" ] || [ -f "releases/uptime-windows-${VERSION}.tar.gz" ]; then
            FILE_SIZE=$(du -h "$OUTPUT_ZIP" 2>/dev/null | cut -f1 || du -h "releases/uptime-windows-${VERSION}.tar.gz" | cut -f1)
            echo "✓ Windows build packaged successfully: $OUTPUT_ZIP"
            echo "  File size: $FILE_SIZE"
            echo "  Note: Extract the archive and run uptime.exe"
            WINDOWS_SUCCESS=1
        fi
    else
        echo "WARNING: Windows build not found at $WINDOWS_BUILD_PATH"
    fi
else
    echo "WARNING: Windows build failed or not supported on this platform!"
    echo "  (Windows builds must be run on Windows)"
fi

# Summary
echo ""
echo "============================================================"
echo "Build Summary:"
echo "============================================================"
if [ $ANDROID_SUCCESS -eq 1 ]; then
    echo "✓ Android: releases/uptime-${VERSION}.apk"
else
    echo "✗ Android: Build failed or skipped"
fi
if [ $WINDOWS_SUCCESS -eq 1 ]; then
    echo "✓ Windows: $OUTPUT_ZIP"
else
    echo "✗ Windows: Build failed or skipped"
fi

if [ $ANDROID_SUCCESS -eq 0 ] && [ $WINDOWS_SUCCESS -eq 0 ]; then
    echo ""
    echo "ERROR: No builds succeeded!"
    exit 1
fi

echo ""
echo "============================================================"
echo "Next steps:"
echo "============================================================"
echo ""
echo "1. Create and push git tag:"
echo "   git tag $TAG"
echo "   git push origin $TAG"
echo ""
echo "2. Create GitHub release:"
echo "   https://github.com/ROODAY/SitStandTimer/releases/new"
echo ""
echo "   Release details:"
echo "   - Tag: $TAG"
echo "   - Title: Uptime $VERSION"
echo "   - Description: Alpha release - testing phase"
echo "   - ☑ Mark as pre-release"
if [ $ANDROID_SUCCESS -eq 1 ]; then
    echo "   - Upload: releases/uptime-${VERSION}.apk"
fi
if [ $WINDOWS_SUCCESS -eq 1 ]; then
    echo "   - Upload: $OUTPUT_ZIP"
fi
echo ""
echo "3. Share the release link with your testers!"
echo ""
