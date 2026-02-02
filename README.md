# Uptime

A simple sit/stand timer app for Android, iOS, and Windows.

## Building and Releasing

### Single Source of Truth
The version is defined **once** in `pubspec.yaml`. All builds, tags, and releases use this version automatically.

### Quick Release Workflow

1. **Update version** (if needed):
   ```powershell
   .\bump_version.ps1 alpha    # For alpha releases
   .\bump_version.ps1 beta     # For beta releases
   .\bump_version.ps1 patch    # For patch releases
   ```

2. **Build and prepare release**:
   ```powershell
   .\build_and_release.ps1
   ```
   This will:
   - Read version from `pubspec.yaml`
   - Build the Android APK
   - Build the Windows executable and package it as a ZIP
   - Show you the exact commands to create the GitHub release

3. **Create GitHub release**:
   - Follow the instructions shown by the script
   - Upload the APK and/or Windows ZIP from the `releases/` folder
   - Mark as pre-release for alpha/beta versions

### Version Bumping

The `bump_version.ps1` script helps increment versions:
- `alpha` - Increment alpha version (0.1.0-alpha.1 → 0.1.0-alpha.2)
- `beta` - Move to beta (0.1.0-alpha.1 → 0.1.0-beta.1)
- `rc` - Move to release candidate (0.1.0-beta.1 → 0.1.0-rc.1)
- `patch` - Bump patch version (0.1.0 → 0.1.1)
- `minor` - Bump minor version (0.1.0 → 0.2.0)
- `major` - Bump major version (0.1.0 → 1.0.0)

### Manual Version Update

Just edit `version:` in `pubspec.yaml` - the build scripts will automatically use it.

## Building and Testing on Windows

### Prerequisites

1. **Enable Windows desktop support** (if not already enabled):
   ```powershell
   flutter config --enable-windows-desktop
   ```

2. **Verify Windows is available**:
   ```powershell
   flutter devices
   ```
   You should see `Windows (desktop)` in the list.

### Running on Windows

**Run in debug mode:**
```powershell
flutter run -d windows
```

**Run in release mode:**
```powershell
flutter run -d windows --release
```

### Building Windows Executable

**Debug build:**
```powershell
flutter build windows --debug
```
Output: `build\windows\x64\runner\Debug\uptime.exe`

**Release build:**
```powershell
flutter build windows --release
```
Output: `build\windows\x64\runner\Release\uptime.exe`

**Using the build script:**
The `build_and_release.ps1` script automatically builds Windows and creates a ZIP file containing the executable and all required DLLs. Users can extract the ZIP and run `uptime.exe` directly - no installation required.

**Note:** For a more professional installer (MSIX), you can use the `msix` package, but the ZIP approach is simpler and works well for distribution.

### Code Signing Windows Executable

To avoid the "Unknown Publisher" warning when users run your Windows executable, you can sign it with a code signing certificate. The build script supports automatic code signing if configured.

**Option 1: Using a PFX Certificate File**

1. Obtain a code signing certificate (from a Certificate Authority like DigiCert, Sectigo, etc.) or create a self-signed certificate for testing
2. Set environment variables before running the build script:
   ```powershell
   $env:WINDOWS_SIGN_CERT_PATH = "C:\path\to\your\certificate.pfx"
   $env:WINDOWS_SIGN_CERT_PASSWORD = "your-certificate-password"
   .\build_and_release.ps1
   ```

**Option 2: Using a Certificate from Windows Certificate Store**

1. Import your certificate into the Windows certificate store
2. Find the certificate thumbprint:
   ```powershell
   Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object {$_.Subject -like "*Your Name*"} | Select-Object Thumbprint, Subject
   ```
3. Set environment variables before running the build script:
   ```powershell
   $env:WINDOWS_SIGN_CERT_THUMBPRINT = "your-certificate-thumbprint"
   $env:WINDOWS_SIGN_CERT_STORE = "My"  # Optional, defaults to "My"
   .\build_and_release.ps1
   ```

**Requirements:**
- Windows SDK must be installed (for `signtool.exe`)
- The script will automatically locate `signtool.exe` in the Windows SDK installation
- If no certificate is configured, the build will complete without signing (you'll see a note in the output)

**Note:** Self-signed certificates will still show a warning, but it's better than "Unknown Publisher". For production releases, use a certificate from a trusted Certificate Authority.

### Testing Notifications on Windows

The app uses `flutter_local_notifications` which supports Windows. Notifications will appear in the Windows notification center:

1. Start the timer in the app
2. Wait for the scheduled notification time
3. Check the Windows notification center (bottom-right corner) for notifications

**Note:** Windows doesn't require notification permissions like Android, so notifications should work immediately.

### Troubleshooting

- If you see errors about missing Windows support, ensure you've run `flutter config --enable-windows-desktop`
- If notifications don't appear, check Windows notification settings to ensure notifications are enabled for the app
- The app will work the same way as on Android - notifications are scheduled and will appear at the appropriate times
