import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _themeModeKey = 'theme_mode';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_themeModeKey);
    if (stored == null) return;
    final mode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    if (mounted) setState(() => _themeMode = mode);
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    final prefs = await SharedPreferences.getInstance();
    final value = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await prefs.setString(_themeModeKey, value);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.light),
      darkTheme: ThemeData(brightness: Brightness.dark),
      themeMode: _themeMode,
      home: UptimeScreen(
        themeMode: _themeMode,
        onThemeModeChanged: _setThemeMode,
      ),
    );
  }
}

class UptimeScreen extends StatefulWidget {
  const UptimeScreen({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<UptimeScreen> createState() => _UptimeScreenState();
}

class _UptimeScreenState extends State<UptimeScreen> with WidgetsBindingObserver {
  int sitMinutes = 30;
  int standMinutes = 30;
  bool walkEnabled = false;
  int walkMinutes = 5;
  int walkFrequency = 2; // every N cycles
  String startPhase = 'Sit';
  String currentPhase = 'Sit';
  bool isRunning = false;
  bool isPaused = false;
  Timer? _timer;
  Timer? _scheduledWarningTimer; // Windows/Linux: warning notification
  Timer? _scheduledPhaseSwitchTimer; // Windows/Linux: phase switch notification
  int _remainingSeconds = 0;
  int _walkCycleCounter = 0;
  bool developerMode = false;
  bool useSeconds = false; // true: seconds, false: minutes
  int warningTime = 5; // minutes (or seconds in dev mode)
  FlutterLocalNotificationsPlugin? flutterLocalNotificationsPlugin;
  bool _didRequestPermissions = false;
  bool warningEnabled = true;
  bool keepScreenOn = false;
  bool _notificationsInitialized = false;
  DateTime? _phaseStartTime; // Track when current phase started
  int _phaseDurationSeconds = 0; // Total duration of current phase

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initNotifications();
    // _requestNotificationPermission(); // Moved to didChangeDependencies
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && isRunning && !isPaused) {
      // App came back to foreground - recalculate remaining time
      _syncTimerWithReality();
    }
  }
  
  void _syncTimerWithReality() {
    if (_phaseStartTime == null || _phaseDurationSeconds == 0) return;
    
    final now = DateTime.now();
    final elapsed = now.difference(_phaseStartTime!).inSeconds;
    final newRemaining = _phaseDurationSeconds - elapsed;
    
    if (newRemaining <= 0) {
      // Phase should have completed - trigger it
      _onPhaseComplete();
    } else {
      // Update remaining time to match reality
      setState(() {
        _remainingSeconds = newRemaining;
      });
      print('[DEBUG] Synced timer: elapsed=$elapsed, remaining=$newRemaining');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didRequestPermissions) {
      _didRequestPermissions = true;
      _requestNotificationPermission();
    }
  }

  Future<void> _initNotifications() async {
    try {
      tz.initializeTimeZones();
      
      // FlutterTimezone might not work on Windows, so handle it gracefully
      String currentTimeZone;
      try {
        currentTimeZone = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(currentTimeZone));
      } catch (e) {
        // Fallback for platforms where FlutterTimezone doesn't work (like Windows)
        if (kDebugMode) {
          print('[DEBUG] FlutterTimezone failed, using system timezone: $e');
        }
        currentTimeZone = 'UTC'; // Fallback
        tz.setLocalLocation(tz.getLocation(currentTimeZone));
      }

      flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
      
      // Platform-specific initialization
      if (Platform.isAndroid) {
        // Create notification channels explicitly (required for Android 8.0+)
        const AndroidNotificationChannel phaseWarningChannel = AndroidNotificationChannel(
          'phase_warning',
          'Phase Warning',
          description: 'Warn before phase ends',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        );
        
        const AndroidNotificationChannel phaseSwitchChannel = AndroidNotificationChannel(
          'phase_switch',
          'Phase Switch',
          description: 'Notify when phase switches',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        );
        
        await flutterLocalNotificationsPlugin!
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(phaseWarningChannel);
        
        await flutterLocalNotificationsPlugin!
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(phaseSwitchChannel);
        
        const AndroidInitializationSettings initializationSettingsAndroid =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        const InitializationSettings initializationSettings =
            InitializationSettings(android: initializationSettingsAndroid);
        final bool? initialized = await flutterLocalNotificationsPlugin!.initialize(
          initializationSettings,
          onDidReceiveNotificationResponse: _onNotificationResponse,
          onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
        );
        _notificationsInitialized = initialized ?? false;
        if (kDebugMode) {
          print('[DEBUG] Android notifications initialized: ${initialized ?? false}');
        }
      } else if (Platform.isWindows) {
        // Windows initialization - use Windows-specific settings
        try {
          const WindowsInitializationSettings initializationSettingsWindows =
              WindowsInitializationSettings(
            appName: 'Uptime',
            appUserModelId: 'com.example.Uptime',
            guid: '91ed2d00-88a5-4d3a-952c-19df33332fbc',
          );
          const InitializationSettings initializationSettings =
              InitializationSettings(windows: initializationSettingsWindows);
          final bool? initialized = await flutterLocalNotificationsPlugin!.initialize(
            initializationSettings,
            onDidReceiveNotificationResponse: _onNotificationResponse,
            onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
          );
          _notificationsInitialized = initialized ?? false;
          if (kDebugMode) {
            print('[DEBUG] Windows notifications initialized: ${initialized ?? false}');
            if (!_notificationsInitialized) {
              print('[WARNING] Windows notification initialization returned false or null');
            }
          }
        } catch (initError) {
          print('[ERROR] Windows notification initialization failed: $initError');
          _notificationsInitialized = false;
          rethrow;
        }
      } else if (Platform.isIOS || Platform.isMacOS) {
        const DarwinInitializationSettings darwinSettings =
            DarwinInitializationSettings();
        const InitializationSettings initializationSettings =
            InitializationSettings(
          iOS: darwinSettings,
          macOS: darwinSettings,
        );
        final bool? initialized = await flutterLocalNotificationsPlugin!.initialize(
          initializationSettings,
          onDidReceiveNotificationResponse: _onNotificationResponse,
          onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
        );
        _notificationsInitialized = initialized ?? false;
        if (kDebugMode) {
          print('[DEBUG] Darwin (iOS/macOS) notifications initialized: ${initialized ?? false}');
        }
      } else if (Platform.isLinux) {
        const LinuxInitializationSettings linuxSettings =
            LinuxInitializationSettings(defaultActionName: 'Open');
        const InitializationSettings initializationSettings =
            InitializationSettings(linux: linuxSettings);
        final bool? initialized = await flutterLocalNotificationsPlugin!.initialize(
          initializationSettings,
          onDidReceiveNotificationResponse: _onNotificationResponse,
          onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
        );
        _notificationsInitialized = initialized ?? false;
        if (kDebugMode) {
          print('[DEBUG] Linux notifications initialized: ${initialized ?? false}');
        }
      } else {
        const InitializationSettings initializationSettings =
            InitializationSettings();
        final bool? initialized = await flutterLocalNotificationsPlugin!.initialize(
          initializationSettings,
          onDidReceiveNotificationResponse: _onNotificationResponse,
          onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
        );
        _notificationsInitialized = initialized ?? false;
        if (kDebugMode) {
          print('[DEBUG] Notifications initialized for other platform: ${initialized ?? false}');
        }
      }
    } catch (e, stackTrace) {
      print('[ERROR] Failed to initialize notifications: $e');
      print('[ERROR] Stack trace: $stackTrace');
      _notificationsInitialized = false;
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    if (response.payload == 'delay5') {
      _addTimeToCurrentPhase(5 * (useSeconds ? 1 : 60));
    } else if (response.payload == 'delay10') {
      _addTimeToCurrentPhase(10 * (useSeconds ? 1 : 60));
    }
  }

  Future<bool> _requestNotificationPermission() async {
    // Windows and Linux don't require notification permissions (or use system default)
    if (Platform.isWindows || Platform.isLinux) {
      return true;
    }
    if (Platform.isIOS || Platform.isMacOS) {
      final status = await Permission.notification.request();
      if (!status.isGranted && mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Notification Permission'),
            content: const Text(
              'Please enable notifications in Settings to receive reminders.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return status.isGranted;
    }
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.android) {
      // Request notification permission (required for Android 13+)
      final status = await Permission.notification.request();
      if (!status.isGranted) {
        if (mounted) {
          showDialog(
            context: context,
            builder:
                (context) => AlertDialog(
                  title: const Text('Notification Permission Required'),
                  content: const Text(
                    'Please enable notification permissions in settings to receive reminders.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
          );
        }
        return false;
      }
      // Request exact alarm permission (required for Android 12+)
      // Note: This might not be available on all devices, so we check first
      if (await Permission.scheduleExactAlarm.isDenied) {
        final alarmStatus = await Permission.scheduleExactAlarm.request();
        if (!alarmStatus.isGranted && alarmStatus.isPermanentlyDenied) {
          if (mounted) {
            showDialog(
              context: context,
              builder:
                  (context) => AlertDialog(
                    title: const Text('Alarm Permission Recommended'),
                    content: const Text(
                      'Exact alarm permissions are recommended for accurate reminders. You can enable it in settings.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
            );
          }
        }
      }
      return true;
    }
    return false;
  }

  Future<void> _scheduleWarningNotification() async {
    if (!warningEnabled) return;
    if (flutterLocalNotificationsPlugin == null) {
      print('[ERROR] Notification plugin is null');
      return;
    }
    final int warnSeconds = warningTime * (useSeconds ? 1 : 60);
    final int scheduleDelay = _remainingSeconds - warnSeconds;
    
    // Check notification permission (Android only)
    if (Platform.isAndroid) {
      final notificationStatus = await Permission.notification.status;
      if (!notificationStatus.isGranted) {
        print('[ERROR] Notification permission not granted');
        return;
      }
      
      // Check exact alarm permission (recommended but not always required)
      final alarmStatus = await Permission.scheduleExactAlarm.status;
      final bool canScheduleExact = alarmStatus.isGranted;
      
      print('[DEBUG] Scheduling warning: delay=$scheduleDelay seconds, exact=$canScheduleExact');

      final String delayUnit = useSeconds ? 'sec' : 'min';
      final notificationDetails = AndroidNotificationDetails(
        'phase_warning',
        'Phase Warning',
        channelDescription: 'Warn before phase ends',
        importance: Importance.max,
        priority: Priority.high,
        icon: 'ic_stat_notify', // Notification icon (must be in drawable folder)
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 200, 100, 200]), // Short vibration pattern
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction('delay5', 'Delay 5 $delayUnit'),
          AndroidNotificationAction('delay10', 'Delay 10 $delayUnit'),
        ],
      );

      if (scheduleDelay <= 0) {
        // If the warning time has already passed, show immediately
        await flutterLocalNotificationsPlugin!.show(
          0,
          'Phase ending soon',
          'Current phase ($currentPhase) will end soon. Delay?',
          NotificationDetails(android: notificationDetails),
        );
        return;
      }
      
      final scheduledTime = tz.TZDateTime.now(
        tz.local,
      ).add(Duration(seconds: scheduleDelay));
      
      if (kDebugMode) {
        print('[DEBUG] Scheduling warning notification for: $scheduledTime, curTime: ${DateTime.now()}');
      }
      
      // Use exact scheduling if permission is granted, otherwise use inexact
      try {
        await flutterLocalNotificationsPlugin!.zonedSchedule(
          0,
          'Phase ending soon',
          'Current phase ($currentPhase) will end soon. Delay?',
          scheduledTime,
          NotificationDetails(android: notificationDetails),
          androidScheduleMode: canScheduleExact 
              ? AndroidScheduleMode.exactAllowWhileIdle 
              : AndroidScheduleMode.inexactAllowWhileIdle,
        );
        print('[DEBUG] Warning notification scheduled successfully for $scheduledTime');
      } catch (e) {
        print('[ERROR] Failed to schedule warning notification: $e');
        // Fallback: show immediately if scheduling fails
        await flutterLocalNotificationsPlugin!.show(
          0,
          'Phase ending soon',
          'Current phase ($currentPhase) will end soon. Delay?',
          NotificationDetails(android: notificationDetails),
        );
      }
    } else if (Platform.isWindows) {
      // Windows doesn't support zonedSchedule, so we use a Timer instead
      print('[DEBUG] Scheduling warning: delay=$scheduleDelay seconds');
      
      if (scheduleDelay <= 0) {
        // If the warning time has already passed, show immediately
        const WindowsNotificationDetails windowsNotificationDetails =
            WindowsNotificationDetails();
        await flutterLocalNotificationsPlugin!.show(
          0,
          'Phase ending soon',
          'Current phase ($currentPhase) will end soon.',
          const NotificationDetails(windows: windowsNotificationDetails),
        );
        return;
      }
      
      // Cancel any existing Windows warning timer
      _scheduledWarningTimer?.cancel();
      
      // Use a Timer to show the notification after the delay
      _scheduledWarningTimer = Timer(Duration(seconds: scheduleDelay), () async {
        const WindowsNotificationDetails windowsNotificationDetails =
            WindowsNotificationDetails();
        try {
          await flutterLocalNotificationsPlugin!.show(
            0,
            'Phase ending soon',
            'Current phase ($currentPhase) will end soon.',
            const NotificationDetails(windows: windowsNotificationDetails),
          );
          print('[DEBUG] Warning notification shown via Timer');
        } catch (e) {
          print('[ERROR] Failed to show warning notification: $e');
        }
      });
      
      if (kDebugMode) {
        final scheduledTime = DateTime.now().add(Duration(seconds: scheduleDelay));
        print('[DEBUG] Warning notification scheduled via Timer for: $scheduledTime');
      }
    } else if (Platform.isIOS || Platform.isMacOS) {
      const DarwinNotificationDetails darwinDetails =
          DarwinNotificationDetails(presentSound: true, presentAlert: true);
      if (scheduleDelay <= 0) {
        await flutterLocalNotificationsPlugin!.show(
          0,
          'Phase ending soon',
          'Current phase ($currentPhase) will end soon.',
          const NotificationDetails(iOS: darwinDetails, macOS: darwinDetails),
        );
        return;
      }
      final scheduledTime = tz.TZDateTime.now(tz.local).add(Duration(seconds: scheduleDelay));
      try {
        await flutterLocalNotificationsPlugin!.zonedSchedule(
          0,
          'Phase ending soon',
          'Current phase ($currentPhase) will end soon.',
          scheduledTime,
          const NotificationDetails(iOS: darwinDetails, macOS: darwinDetails),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      } catch (e) {
        print('[ERROR] Failed to schedule warning notification: $e');
        await flutterLocalNotificationsPlugin!.show(
          0,
          'Phase ending soon',
          'Current phase ($currentPhase) will end soon.',
          const NotificationDetails(iOS: darwinDetails, macOS: darwinDetails),
        );
      }
    } else if (Platform.isLinux) {
      print('[DEBUG] Scheduling warning: delay=$scheduleDelay seconds (Linux)');
      if (scheduleDelay <= 0) {
        const LinuxNotificationDetails linuxDetails = LinuxNotificationDetails();
        await flutterLocalNotificationsPlugin!.show(
          0,
          'Phase ending soon',
          'Current phase ($currentPhase) will end soon.',
          const NotificationDetails(linux: linuxDetails),
        );
        return;
      }
      _scheduledWarningTimer?.cancel();
      _scheduledWarningTimer = Timer(Duration(seconds: scheduleDelay), () async {
        const LinuxNotificationDetails linuxDetails = LinuxNotificationDetails();
        try {
          await flutterLocalNotificationsPlugin!.show(
            0,
            'Phase ending soon',
            'Current phase ($currentPhase) will end soon.',
            const NotificationDetails(linux: linuxDetails),
          );
        } catch (e) {
          print('[ERROR] Failed to show warning notification: $e');
        }
      });
    }
  }

  Future<void> _schedulePhaseSwitchNotification(
    String nextPhase,
    int secondsUntilSwitch,
  ) async {
    if (flutterLocalNotificationsPlugin == null) {
      print('[ERROR] Notification plugin is null');
      return;
    }
    
    if (Platform.isAndroid) {
      // Check notification permission (required)
      final notificationStatus = await Permission.notification.status;
      if (!notificationStatus.isGranted) {
        print('[ERROR] Notification permission not granted');
        return;
      }
      
      // Check exact alarm permission (recommended but not always required)
      final alarmStatus = await Permission.scheduleExactAlarm.status;
      final bool canScheduleExact = alarmStatus.isGranted;
      
      print('[DEBUG] Scheduling phase switch: nextPhase=$nextPhase, delay=$secondsUntilSwitch seconds, exact=$canScheduleExact');

      final notificationDetails = AndroidNotificationDetails(
        'phase_switch',
        'Phase Switch',
        channelDescription: 'Notify when phase switches',
        importance: Importance.max,
        priority: Priority.high,
        icon: 'ic_stat_notify', // Notification icon (must be in drawable folder)
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 250, 250, 250]), // Vibrate pattern: wait 0ms, vibrate 250ms, pause 250ms, vibrate 250ms
      );

      if (secondsUntilSwitch <= 0) {
        // Cancel the warning notification (ID 0) when phase switch happens
        await flutterLocalNotificationsPlugin!.cancel(0);
        await flutterLocalNotificationsPlugin!.show(
          1,
          'Phase switched',
          'It\'s time to $nextPhase!',
          NotificationDetails(android: notificationDetails),
        );
        return;
      }
      
      final curTime = tz.TZDateTime.now(tz.local);
      final scheduledTime = curTime.add(Duration(seconds: secondsUntilSwitch));
      
      print('[DEBUG] Scheduling phase switch notification for: $scheduledTime, nextPhase: $nextPhase');
      
      // Use exact scheduling if permission is granted, otherwise use inexact
      // Note: matchDateTimeComponents is removed as it's for recurring notifications only
      try {
        await flutterLocalNotificationsPlugin!.zonedSchedule(
          1,
          'Phase switched',
          'It\'s time to $nextPhase!',
          scheduledTime,
          NotificationDetails(android: notificationDetails),
          androidScheduleMode: canScheduleExact 
              ? AndroidScheduleMode.exactAllowWhileIdle 
              : AndroidScheduleMode.inexactAllowWhileIdle,
        );
        print('[DEBUG] Phase switch notification scheduled successfully for $scheduledTime (now: ${DateTime.now()})');
      } catch (e) {
        print('[ERROR] Failed to schedule phase switch notification: $e');
        // Fallback: show immediately if scheduling fails
        await flutterLocalNotificationsPlugin!.cancel(0);
        await flutterLocalNotificationsPlugin!.show(
          1,
          'Phase switched',
          'It\'s time to $nextPhase!',
          NotificationDetails(android: notificationDetails),
        );
      }
      
      // Cancel the warning notification when phase switch is scheduled
      // We'll also cancel it when the notification actually fires, but this helps if timing is close
      if (secondsUntilSwitch <= 5) {
        await flutterLocalNotificationsPlugin!.cancel(0);
      }
    } else if (Platform.isWindows) {
      // Windows doesn't support zonedSchedule, so we use a Timer instead
      print('[DEBUG] Scheduling phase switch: nextPhase=$nextPhase, delay=$secondsUntilSwitch seconds');
      
      const WindowsNotificationDetails windowsNotificationDetails =
          WindowsNotificationDetails();

      if (secondsUntilSwitch <= 0) {
        // Cancel the warning notification (ID 0) when phase switch happens
        _scheduledWarningTimer?.cancel();
        _scheduledPhaseSwitchTimer?.cancel();
        await flutterLocalNotificationsPlugin!.cancel(0);
        await flutterLocalNotificationsPlugin!.show(
          1,
          'Phase switched',
          'It\'s time to $nextPhase!',
          const NotificationDetails(windows: windowsNotificationDetails),
        );
        return;
      }
      
      // Cancel any existing Windows phase switch timer
      _scheduledPhaseSwitchTimer?.cancel();
      
      // Use a Timer to show the notification after the delay
      _scheduledPhaseSwitchTimer = Timer(Duration(seconds: secondsUntilSwitch), () async {
        try {
          // Cancel warning notification when phase switch fires
          _scheduledWarningTimer?.cancel();
          await flutterLocalNotificationsPlugin!.cancel(0);
          await flutterLocalNotificationsPlugin!.show(
            1,
            'Phase switched',
            'It\'s time to $nextPhase!',
            const NotificationDetails(windows: windowsNotificationDetails),
          );
          print('[DEBUG] Phase switch notification shown via Timer');
        } catch (e) {
          print('[ERROR] Failed to show phase switch notification: $e');
        }
      });
      
      if (kDebugMode) {
        final scheduledTime = DateTime.now().add(Duration(seconds: secondsUntilSwitch));
        print('[DEBUG] Phase switch notification scheduled via Timer for: $scheduledTime, nextPhase: $nextPhase');
      }
      
      // Cancel the warning notification when phase switch is very close
      if (secondsUntilSwitch <= 5) {
        _scheduledWarningTimer?.cancel();
        await flutterLocalNotificationsPlugin!.cancel(0);
      }
    } else if (Platform.isIOS || Platform.isMacOS) {
      const DarwinNotificationDetails darwinDetails =
          DarwinNotificationDetails(presentSound: true, presentAlert: true);
      if (secondsUntilSwitch <= 0) {
        await flutterLocalNotificationsPlugin!.cancel(0);
        await flutterLocalNotificationsPlugin!.show(
          1,
          'Phase switched',
          'It\'s time to $nextPhase!',
          const NotificationDetails(iOS: darwinDetails, macOS: darwinDetails),
        );
        return;
      }
      final scheduledTime = tz.TZDateTime.now(tz.local).add(Duration(seconds: secondsUntilSwitch));
      try {
        await flutterLocalNotificationsPlugin!.zonedSchedule(
          1,
          'Phase switched',
          'It\'s time to $nextPhase!',
          scheduledTime,
          const NotificationDetails(iOS: darwinDetails, macOS: darwinDetails),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      } catch (e) {
        print('[ERROR] Failed to schedule phase switch notification: $e');
        await flutterLocalNotificationsPlugin!.cancel(0);
        await flutterLocalNotificationsPlugin!.show(
          1,
          'Phase switched',
          'It\'s time to $nextPhase!',
          const NotificationDetails(iOS: darwinDetails, macOS: darwinDetails),
        );
      }
      if (secondsUntilSwitch <= 5) {
        await flutterLocalNotificationsPlugin!.cancel(0);
      }
    } else if (Platform.isLinux) {
      print('[DEBUG] Scheduling phase switch (Linux): nextPhase=$nextPhase, delay=$secondsUntilSwitch seconds');
      const LinuxNotificationDetails linuxDetails = LinuxNotificationDetails();
      if (secondsUntilSwitch <= 0) {
        _scheduledWarningTimer?.cancel();
        _scheduledPhaseSwitchTimer?.cancel();
        await flutterLocalNotificationsPlugin!.cancel(0);
        await flutterLocalNotificationsPlugin!.show(
          1,
          'Phase switched',
          'It\'s time to $nextPhase!',
          const NotificationDetails(linux: linuxDetails),
        );
        return;
      }
      _scheduledPhaseSwitchTimer?.cancel();
      _scheduledPhaseSwitchTimer = Timer(Duration(seconds: secondsUntilSwitch), () async {
        try {
          _scheduledWarningTimer?.cancel();
          await flutterLocalNotificationsPlugin!.cancel(0);
          await flutterLocalNotificationsPlugin!.show(
            1,
            'Phase switched',
            'It\'s time to $nextPhase!',
            const NotificationDetails(linux: linuxDetails),
          );
        } catch (e) {
          print('[ERROR] Failed to show phase switch notification: $e');
        }
      });
      if (secondsUntilSwitch <= 5) {
        _scheduledWarningTimer?.cancel();
        await flutterLocalNotificationsPlugin!.cancel(0);
      }
    }
  }

  void _startTimer() async {
    // Ensure permissions are granted before starting
    final hasPermission = await _requestNotificationPermission();
    if (!hasPermission && mounted) {
      // Show a warning but allow timer to start anyway
      if (kDebugMode) {
        print('[DEBUG] Starting timer without notification permissions');
      }
    }
    
    // Enable wake lock if requested
    if (keepScreenOn) {
      await WakelockPlus.enable();
    }
    
    setState(() {
      isRunning = true;
      isPaused = false;
      currentPhase = startPhase;
      _walkCycleCounter = 0;
      _setPhaseDuration();
    });
    _runTimer();
    // _cancelAllNotifications();
    _scheduleWarningNotification();
    _schedulePhaseSwitchNotification(_getNextPhase(), _remainingSeconds);
  }

  String _getNextPhase() {
    if (currentPhase == 'Sit') {
      return 'Stand';
    } else if (currentPhase == 'Stand' &&
        walkEnabled &&
        _walkCycleCounter + 1 >= walkFrequency) {
      return 'Walk';
    } else {
      return 'Sit';
    }
  }

  void _runTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!isPaused && isRunning) {
        if (_remainingSeconds > 0) {
          setState(() {
            _remainingSeconds--;
          });
        } else {
          // Phase complete - cancel timer first to prevent race conditions
          timer.cancel();
          _onPhaseComplete();
        }
      }
    });
  }

  void _setPhaseDuration() {
    int multiplier = useSeconds ? 1 : 60;
    switch (currentPhase) {
      case 'Sit':
        _phaseDurationSeconds = sitMinutes * multiplier;
        break;
      case 'Stand':
        _phaseDurationSeconds = standMinutes * multiplier;
        break;
      case 'Walk':
        _phaseDurationSeconds = walkMinutes * multiplier;
        break;
    }
    _remainingSeconds = _phaseDurationSeconds;
    _phaseStartTime = DateTime.now(); // Record when phase started
  }

  void _onPhaseComplete() {
    // Cancel timer immediately to prevent race conditions
    _timer?.cancel();
    
    // Get next phase before state changes
    final nextPhase = _getNextPhase();
    
    // Update phase synchronously first to prevent stuck state
    // This must happen in setState to update the UI
    setState(() {
      _proceedToNextPhase();
    });
    
    // Then handle async operations and restart timer
    if (isRunning) {
      _runTimer();
      // Schedule notifications asynchronously
      _handlePhaseCompleteNotifications(nextPhase);
    }
  }
  
  Future<void> _handlePhaseCompleteNotifications(String nextPhase) async {
    // Cancel warning notification when phase completes
    _scheduledWarningTimer?.cancel();
    _scheduledPhaseSwitchTimer?.cancel();
    await flutterLocalNotificationsPlugin?.cancel(0);
    await flutterLocalNotificationsPlugin?.cancel(1);
    
    // Show phase switch notification immediately (the scheduled one might have already fired or will be cancelled)
    if (flutterLocalNotificationsPlugin != null) {
      if (Platform.isAndroid) {
        final notificationStatus = await Permission.notification.status;
        if (notificationStatus.isGranted) {
          final notificationDetails = AndroidNotificationDetails(
            'phase_switch',
            'Phase Switch',
            channelDescription: 'Notify when phase switches',
            importance: Importance.max,
            priority: Priority.high,
            icon: 'ic_stat_notify', // Notification icon (must be in drawable folder)
            enableVibration: true,
            vibrationPattern: Int64List.fromList([0, 250, 250, 250]),
          );
          try {
            await flutterLocalNotificationsPlugin!.show(
              1,
              'Phase switched',
              'It\'s time to $nextPhase!',
              NotificationDetails(android: notificationDetails),
            );
            print('[DEBUG] Phase switch notification shown immediately');
          } catch (e) {
            print('[ERROR] Failed to show phase switch notification: $e');
          }
        }
      } else if (Platform.isWindows) {
        _scheduledWarningTimer?.cancel();
        _scheduledPhaseSwitchTimer?.cancel();
        try {
          const WindowsNotificationDetails windowsNotificationDetails =
              WindowsNotificationDetails();
          await flutterLocalNotificationsPlugin!.show(
            1,
            'Phase switched',
            'It\'s time to $nextPhase!',
            const NotificationDetails(windows: windowsNotificationDetails),
          );
          print('[DEBUG] Phase switch notification shown immediately');
        } catch (e) {
          print('[ERROR] Failed to show phase switch notification: $e');
        }
      } else if (Platform.isIOS || Platform.isMacOS) {
        try {
          const DarwinNotificationDetails darwinDetails =
              DarwinNotificationDetails(presentSound: true, presentAlert: true);
          await flutterLocalNotificationsPlugin!.show(
            1,
            'Phase switched',
            'It\'s time to $nextPhase!',
            const NotificationDetails(iOS: darwinDetails, macOS: darwinDetails),
          );
          print('[DEBUG] Phase switch notification shown immediately');
        } catch (e) {
          print('[ERROR] Failed to show phase switch notification: $e');
        }
      } else if (Platform.isLinux) {
        try {
          const LinuxNotificationDetails linuxDetails = LinuxNotificationDetails();
          await flutterLocalNotificationsPlugin!.show(
            1,
            'Phase switched',
            'It\'s time to $nextPhase!',
            const NotificationDetails(linux: linuxDetails),
          );
          print('[DEBUG] Phase switch notification shown immediately');
        } catch (e) {
          print('[ERROR] Failed to show phase switch notification: $e');
        }
      }
    }
    
    // Schedule next phase notifications
    _scheduleWarningNotification();
    _schedulePhaseSwitchNotification(_getNextPhase(), _remainingSeconds);
  }

  void _addTimeToCurrentPhase(int seconds) {
    setState(() {
      _remainingSeconds += seconds;
      _phaseDurationSeconds += seconds;
      // Adjust start time to account for added time (effectively "rewinding" the clock)
      if (_phaseStartTime != null) {
        _phaseStartTime = _phaseStartTime!.subtract(Duration(seconds: seconds));
      }
    });
    // Cancel and reschedule notifications to reflect new timing
    _cancelAllNotifications();
    if (isRunning) {
      _scheduleWarningNotification();
      _schedulePhaseSwitchNotification(_getNextPhase(), _remainingSeconds);
    }
  }

  void _skipCurrentPhase() {
    _timer?.cancel();
    setState(() {
      _proceedToNextPhase();
    });
    if (isRunning) {
      _runTimer();
    }
  }

  void _proceedToNextPhase() {
    // This method is called from within setState, so don't call setState here
    if (currentPhase == 'Sit') {
      currentPhase = 'Stand';
      _setPhaseDuration();
    } else if (currentPhase == 'Stand') {
      if (walkEnabled) {
        _walkCycleCounter++;
        if (_walkCycleCounter >= walkFrequency) {
          currentPhase = 'Walk';
          _walkCycleCounter = 0;
          _setPhaseDuration();
          return;
        }
      }
      currentPhase = 'Sit';
      _setPhaseDuration();
    } else if (currentPhase == 'Walk') {
      currentPhase = 'Sit';
      _setPhaseDuration();
    }
  }

  void _pauseTimer() async {
    setState(() {
      isPaused = true;
    });
    // Optionally disable wake lock when paused to save battery
    if (keepScreenOn) {
      await WakelockPlus.disable();
    }
  }

  void _resumeTimer() async {
    // Sync timer when resuming in case time passed while paused
    if (_phaseStartTime != null) {
      _syncTimerWithReality();
    }
    setState(() {
      isPaused = false;
    });
    // Re-enable wake lock when resuming if it was enabled
    if (keepScreenOn) {
      await WakelockPlus.enable();
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _cancelAllNotifications();
    // Disable wake lock when stopping
    WakelockPlus.disable();
    setState(() {
      isRunning = false;
      isPaused = false;
      currentPhase = startPhase;
      _remainingSeconds = 0;
    });
  }

  void _cancelAllNotifications() {
    _scheduledWarningTimer?.cancel();
    _scheduledPhaseSwitchTimer?.cancel();
    flutterLocalNotificationsPlugin?.cancelAll();
  }

  Future<void> _testNotification() async {
    // Wait for initialization to complete if it's still in progress
    if (!_notificationsInitialized) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notifications are still initializing. Please wait...')),
        );
      }
      return;
    }
    
    if (flutterLocalNotificationsPlugin == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notifications not initialized')),
        );
      }
      return;
    }

    try {
      if (Platform.isAndroid) {
        final notificationStatus = await Permission.notification.status;
        if (!notificationStatus.isGranted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Notification permission not granted. Please grant permission first.'),
              ),
            );
          }
          return;
        }

        const notificationDetails = AndroidNotificationDetails(
          'phase_switch',
          'Phase Switch',
          channelDescription: 'Notify when phase switches',
          importance: Importance.max,
          priority: Priority.high,
          icon: 'ic_stat_notify', // Notification icon (must be in drawable folder)
        );

        await flutterLocalNotificationsPlugin!.show(
          999,
          'Test Notification',
          'If you see this, notifications are working!',
          NotificationDetails(android: notificationDetails),
        );
    } else if (Platform.isWindows) {
      const WindowsNotificationDetails windowsNotificationDetails =
          WindowsNotificationDetails();
      await flutterLocalNotificationsPlugin!.show(
        999,
        'Test Notification',
        'If you see this, notifications are working!',
        const NotificationDetails(windows: windowsNotificationDetails),
      );
    } else if (Platform.isIOS || Platform.isMacOS) {
      const DarwinNotificationDetails darwinDetails =
          DarwinNotificationDetails(presentSound: true, presentAlert: true);
      await flutterLocalNotificationsPlugin!.show(
        999,
        'Test Notification',
        'If you see this, notifications are working!',
        const NotificationDetails(iOS: darwinDetails, macOS: darwinDetails),
      );
    } else if (Platform.isLinux) {
      const LinuxNotificationDetails linuxDetails = LinuxNotificationDetails();
      await flutterLocalNotificationsPlugin!.show(
        999,
        'Test Notification',
        'If you see this, notifications are working!',
        const NotificationDetails(linux: linuxDetails),
      );
    }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Test notification sent!')),
        );
      }
    } catch (e, stackTrace) {
      print('[ERROR] Failed to show test notification: $e');
      print('[ERROR] Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error showing notification: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _scheduledWarningTimer?.cancel();
    _scheduledPhaseSwitchTimer?.cancel();
    // Always disable wake lock when disposing
    WakelockPlus.disable();
    super.dispose();
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Uptime'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => SettingsScreen(
                    themeMode: widget.themeMode,
                    onThemeModeChanged: widget.onThemeModeChanged,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child:
            isRunning
                ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        'Current Phase: '
                        '$currentPhase',
                        style: const TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      Text(
                        _formatTime(_remainingSeconds),
                        style: const TextStyle(
                          fontSize: 80,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.center,
                        children: [
                          for (var min in [5, 10, 15])
                            ElevatedButton(
                              onPressed:
                                  () => _addTimeToCurrentPhase(
                                    min * (useSeconds ? 1 : 60),
                                  ),
                              style: ElevatedButton.styleFrom(
                                textStyle: const TextStyle(fontSize: 20),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 16,
                                ),
                              ),
                              child: Text(
                                'Add $min ${useSeconds ? 'sec' : 'min'}',
                              ),
                            ),
                          ElevatedButton(
                            onPressed: () async {
                              final controller = TextEditingController();
                              final result = await showDialog<int>(
                                context: context,
                                builder: (dialogContext) {
                                  return AlertDialog(
                                    title: const Text('Custom Add Time'),
                                    content: TextField(
                                      controller: controller,
                                      keyboardType: TextInputType.number,
                                      decoration: InputDecoration(
                                        hintText:
                                            useSeconds ? 'Seconds' : 'Minutes',
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed:
                                            () =>
                                                Navigator.of(
                                                  dialogContext,
                                                ).pop(),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () {
                                          final val = int.tryParse(
                                            controller.text,
                                          );
                                          if (val != null && val > 0) {
                                            Navigator.of(
                                              dialogContext,
                                            ).pop(val * (useSeconds ? 1 : 60));
                                          }
                                        },
                                        child: const Text('OK'),
                                      ),
                                    ],
                                  );
                                },
                              );
                              if (result != null) {
                                _addTimeToCurrentPhase(result);
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 20),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 16,
                              ),
                            ),
                            child: const Text('Custom'),
                          ),
                          ElevatedButton(
                            onPressed: _skipCurrentPhase,
                            style: ElevatedButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 20),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 16,
                              ),
                            ),
                            child: const Text('Skip Phase'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 40),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ElevatedButton(
                            onPressed: isPaused ? _resumeTimer : _pauseTimer,
                            style: ElevatedButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 20),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                                vertical: 18,
                              ),
                            ),
                            child: Text(isPaused ? 'Resume' : 'Pause'),
                          ),
                          const SizedBox(width: 24),
                          ElevatedButton(
                            onPressed: _stopTimer,
                            style: ElevatedButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 20),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                                vertical: 18,
                              ),
                            ),
                            child: const Text('Stop'),
                          ),
                        ],
                      ), // End of Row with Pause/Stop buttons
                    ],
                  ), // End of Column for running state
                )
                : ListView(
                  children: [
                    if (kDebugMode)
                      Column(
                        children: [
                          SwitchListTile(
                            title: const Text('Developer Mode'),
                            value: developerMode,
                            onChanged: (v) => setState(() => developerMode = v),
                          ),
                          if (developerMode) ...[
                            SwitchListTile(
                              title: const Text(
                                'Use Seconds (instead of Minutes)',
                              ),
                              value: useSeconds,
                              onChanged: (v) => setState(() => useSeconds = v),
                            ),
                            ElevatedButton(
                              onPressed: _testNotification,
                              child: const Text('Test Notification'),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ),
                    Row(
                      children: [
                        const Text('Sit'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: sitMinutes.toDouble(),
                            min: 5,
                            max: 120,
                            divisions: 23,
                            label: sitMinutes.toString(),
                            onChanged:
                                (v) => setState(() => sitMinutes = v.round()),
                          ),
                        ),
                        Text('$sitMinutes ${useSeconds ? 'sec' : 'min'}'),
                      ],
                    ),
                    Row(
                      children: [
                        const Text('Stand'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: standMinutes.toDouble(),
                            min: 5,
                            max: 120,
                            divisions: 23,
                            label: standMinutes.toString(),
                            onChanged:
                                (v) => setState(() => standMinutes = v.round()),
                          ),
                        ),
                        Text('$standMinutes ${useSeconds ? 'sec' : 'min'}'),
                      ],
                    ),
                    SwitchListTile(
                      title: const Text('Enable Walk Phase'),
                      value: walkEnabled,
                      onChanged: (v) => setState(() => walkEnabled = v),
                    ),
                    if (walkEnabled) ...[
                      Row(
                        children: [
                          const Text('Walk'),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Slider(
                              value: walkMinutes.toDouble(),
                              min: 1,
                              max: 30,
                              divisions: 29,
                              label: walkMinutes.toString(),
                              onChanged:
                                  (v) => setState(() => walkMinutes = v.round()),
                            ),
                          ),
                          Text('$walkMinutes ${useSeconds ? 'sec' : 'min'}'),
                        ],
                      ),
                      Row(
                        children: [
                          const Text('Walk every'),
                          const SizedBox(width: 8),
                          DropdownButton<int>(
                            value: walkFrequency,
                            items: List.generate(10, (i) => i + 1)
                                .map((e) => DropdownMenuItem(
                                      value: e,
                                      child: Text('$e cycle${e > 1 ? 's' : ''}'),
                                    ))
                                .toList(),
                            onChanged: (v) => setState(() => walkFrequency = v ?? 1),
                          ),
                        ],
                      ),
                    ],
                    SwitchListTile(
                      title: const Text('Keep Screen On'),
                      subtitle: const Text('Prevent screen from sleeping while timer is running'),
                      value: keepScreenOn,
                      onChanged: (v) async {
                        setState(() => keepScreenOn = v);
                        if (v) {
                          await WakelockPlus.enable();
                        } else {
                          await WakelockPlus.disable();
                        }
                      },
                    ),
                    SwitchListTile(
                      title: const Text('Enable Warning Notification'),
                      value: warningEnabled,
                      onChanged: (v) => setState(() => warningEnabled = v),
                    ),
                    if (warningEnabled)
                      Row(
                        children: [
                          const Text('Warn before phase ends:'),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Slider(
                              value: warningTime.toDouble(),
                              min: 1,
                              max: useSeconds ? 30 : 30,
                              divisions: 29,
                              label: warningTime.toString(),
                              onChanged: (v) => setState(() => warningTime = v.round()),
                            ),
                          ),
                          Text('$warningTime ${useSeconds ? 'sec' : 'min'}'),
                        ],
                      ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Start with:'),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: startPhase,
                          items: [
                            const DropdownMenuItem(value: 'Sit', child: Text('Sit')),
                            const DropdownMenuItem(value: 'Stand', child: Text('Stand')),
                            if (walkEnabled)
                              const DropdownMenuItem(value: 'Walk', child: Text('Walk')),
                          ],
                          onChanged: (v) => setState(() => startPhase = v ?? 'Sit'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton(
                          onPressed: _startTimer,
                          child: const Text('Start'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Appearance',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          RadioListTile<ThemeMode>(
            title: const Text('System default'),
            subtitle: const Text('Follow device light/dark setting'),
            value: ThemeMode.system,
            groupValue: themeMode,
            onChanged: (value) {
              if (value != null) {
                onThemeModeChanged(value);
                Navigator.of(context).pop();
              }
            },
          ),
          RadioListTile<ThemeMode>(
            title: const Text('Light'),
            value: ThemeMode.light,
            groupValue: themeMode,
            onChanged: (value) {
              if (value != null) {
                onThemeModeChanged(value);
                Navigator.of(context).pop();
              }
            },
          ),
          RadioListTile<ThemeMode>(
            title: const Text('Dark'),
            value: ThemeMode.dark,
            groupValue: themeMode,
            onChanged: (value) {
              if (value != null) {
                onThemeModeChanged(value);
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
    );
  }
}

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  // This function is required for background notification action handling.
  // You can add logic here if needed, or just leave it as a stub.
}
