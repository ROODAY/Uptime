# Uptime Development Notes

## Testing macOS Notifications

To test notification permissions as a "new user":

1. Go to **System Settings > Notifications**
2. Find "Uptime" in the app list
3. **Right-click** on it and select "Reset" to clear permission state
4. Relaunch the app

**Note:** macOS notification behavior differs from iOS:
- macOS may not always show a permission prompt dialog
- Apps often get registered in Settings with notifications disabled by default
- Users must manually enable notifications in System Settings

## macOS Notification Configuration

Key Info.plist setting for notification style:
```xml
<key>NSUserNotificationAlertStyle</key>
<string>alert</string>
```

Valid values:
- `none` - no visual notification
- `banner` - temporary banner that auto-dismisses
- `alert` - persistent alert until user dismisses (recommended for timer apps)
