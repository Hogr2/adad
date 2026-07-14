// ============================================================================
// Multi-Habit Tracker — main.dart (v6)
//
// New in this version:
//   1. Dark Mode: global toggle (Sun/Moon icon in AppBar), persisted in
//      shared_preferences, deep-grey dark theme (0xFF121212) where the
//      pastel/muted palette colors still read clearly as accents.
//   2. Per-habit local notifications via flutter_local_notifications +
//      timezone:
//      - Each habit can have its own optional daily reminder time, set from
//        the Add/Edit Habit dialog. Notification content includes the
//        habit's name (e.g. "Reminder: Drink Water").
//      - Reminders are scheduled with a notification ID derived from the
//        habit's id, so habits' alarms don't clobber each other.
//      - Scheduled with AndroidScheduleMode.exactAllowWhileIdle to bypass
//        Doze, with an automatic fallback to inexact delivery if the exact
//        alarm permission is denied/revoked (so a permission failure
//        degrades gracefully instead of losing the reminder or crashing).
//      - Every habit with a reminder set is re-scheduled whenever the habit
//        list loads, as a safety net in addition to the boot receiver.
//      - Explicit runtime permission requests for Android 13+/14:
//        POST_NOTIFICATIONS and exact-alarm permission.
//
// REQUIRED DEPENDENCIES (pubspec.yaml -> dependencies:):
//   shared_preferences: ^2.2.2
//   flutter_local_notifications: ^18.0.1
//   timezone: ^0.9.4
//   flutter_timezone: ^3.0.0
//
// REQUIRED AndroidManifest.xml permissions: POST_NOTIFICATIONS,
// SCHEDULE_EXACT_ALARM, USE_EXACT_ALARM, RECEIVE_BOOT_COMPLETED, WAKE_LOCK,
// VIBRATE, plus the ScheduledNotificationBootReceiver receiver entry.
// ============================================================================

import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';

// =============================================================================
// GLOBAL THEME STATE
// A ValueNotifier is the simplest way to let any screen flip the app-wide
// theme without threading a callback through every widget constructor.
// =============================================================================

final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(
  ThemeMode.light,
);
const _kIsDarkModeKey = 'is_dark_mode';

// =============================================================================
// NOTIFICATION SERVICE
// Wraps flutter_local_notifications + timezone setup, permission requests,
// and daily-repeating scheduling in one place.
// =============================================================================

class NotificationService {
  NotificationService._internal();
  static final NotificationService instance = NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Local scheduled notifications only exist on mobile.
  /// flutter_local_notifications has no web implementation, and iOS Safari
  /// can't do locally-scheduled notifications at all — so on web every
  /// public method of this service is an early-return no-op. Guarding here
  /// (instead of at each call site) keeps Android behavior byte-for-byte
  /// identical while making it impossible for the web build to touch the
  /// native-only plugin stack.
  static bool get supportsNotifications => !kIsWeb;

  Future<void> init() async {
    if (!supportsNotifications) return;
    try {
      // Timezone database must be initialized before any zonedSchedule call.
      tz.initializeTimeZones();
      try {
        final String currentTimeZone = await FlutterTimezone.getLocalTimezone();
        print(
            '[NotificationService] Device reports timezone: $currentTimeZone');
        tz.setLocalLocation(tz.getLocation(currentTimeZone));
        print('[NotificationService] tz.local resolved to: ${tz.local.name}');
      } catch (e, st) {
        // If timezone lookup fails for any reason, fall back to UTC rather
        // than crashing — the daily reminder will just use UTC-local time.
        // This used to fail silently with no trace in the console, which
        // made a UTC-vs-local mismatch impossible to diagnose.
        print(
          '[NotificationService] Failed to resolve local timezone, '
          'falling back to UTC ("${tz.local.name}"). Error: $e',
        );
        developer.log(
          'Failed to resolve local timezone, falling back to UTC',
          error: e,
          stackTrace: st,
          name: 'NotificationService',
        );
      }

      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      const initSettings = InitializationSettings(android: androidSettings);
      await _plugin.initialize(initSettings);

      // Notifications and exact-alarm permissions both require explicit
      // runtime requests on Android 13+/14. Each is wrapped separately so a
      // denial or platform exception on one doesn't stop the other, or crash
      // app startup.
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

      // Explicitly create the channel at init time (rather than relying on
      // it being created implicitly by the first scheduled notification) so
      // its settings — importance in particular — are guaranteed to be in
      // effect from first launch.
      try {
        await androidImpl?.createNotificationChannel(
          const AndroidNotificationChannel(
            'habit_reminder_channel',
            'Habit Reminders',
            description: 'Per-habit daily reminder notifications',
            importance: Importance.max,
          ),
        );
      } catch (e, st) {
        developer.log(
          'Failed to create habit reminder notification channel',
          error: e,
          stackTrace: st,
          name: 'NotificationService',
        );
      }
      try {
        await androidImpl?.requestNotificationsPermission();
      } catch (e, st) {
        developer.log(
          'Failed to request notification permission',
          error: e,
          stackTrace: st,
          name: 'NotificationService',
        );
      }
      try {
        await androidImpl?.requestExactAlarmsPermission();
      } catch (e, st) {
        developer.log(
          'Failed to request exact-alarm permission',
          error: e,
          stackTrace: st,
          name: 'NotificationService',
        );
      }
    } catch (e, st) {
      // Never let notification setup take the whole app down with it.
      developer.log(
        'NotificationService.init failed',
        error: e,
        stackTrace: st,
        name: 'NotificationService',
      );
    }
  }

  // Deterministic per-habit notification ID, derived from the habit's id so
  // each habit's reminder can be scheduled/cancelled independently without
  // clobbering any other habit's alarm. Masked to a positive 31-bit value
  // since Android notification IDs are a native (32-bit signed) int.
  int _habitNotificationId(String habitId) => habitId.hashCode & 0x7FFFFFFF;

  Future<void> scheduleHabitReminder(Habit habit, TimeOfDay time) async {
    if (!supportsNotifications) return;
    try {
      final notificationId = _habitNotificationId(habit.id);
      await _plugin.cancel(notificationId);

      final now = tz.TZDateTime.now(tz.local);
      var scheduled = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day,
        time.hour,
        time.minute,
      );
      if (scheduled.isBefore(now)) {
        scheduled = scheduled.add(const Duration(days: 1));
      }

      print(
        '[NotificationService] Scheduling "${habit.name}" '
        '(notificationId=$notificationId) — tz.local=${tz.local.name}, '
        'now=$now, requestedTime=${time.hour}:${time.minute.toString().padLeft(2, '0')}, '
        'scheduledFor=$scheduled '
        '(${scheduled.difference(now).inSeconds}s from now)',
      );

      Future<void> fire(AndroidScheduleMode mode) => _plugin.zonedSchedule(
            notificationId,
            'Reminder: ${habit.name}',
            'Time to work on your habit! 🌱',
            scheduled,
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'habit_reminder_channel',
                'Habit Reminders',
                channelDescription: 'Per-habit daily reminder notifications',
                importance: Importance.max,
                priority: Priority.high,
              ),
            ),
            androidScheduleMode: mode,
            // Required by the current flutter_local_notifications API: tells the
            // plugin the DateTime we passed is already an absolute point in time
            // (as opposed to a wall-clock time that should be reinterpreted).
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            // Repeats every day at the same time.
            matchDateTimeComponents: DateTimeComponents.time,
          );

      try {
        // Exact alarms bypass Doze so the reminder actually fires on time;
        // this requires SCHEDULE_EXACT_ALARM/USE_EXACT_ALARM plus the
        // runtime permission requested in init().
        await fire(AndroidScheduleMode.exactAllowWhileIdle);
        print(
          '[NotificationService] Used exactAllowWhileIdle for "${habit.name}"',
        );
      } catch (e, st) {
        // Permission denied/revoked (SecurityException on Android 12+) —
        // fall back to inexact delivery rather than losing the reminder or
        // crashing the app.
        print(
          '[NotificationService] exactAllowWhileIdle FAILED for '
          '"${habit.name}": $e — falling back to inexactAllowWhileIdle',
        );
        developer.log(
          'Exact alarm scheduling failed for habit "${habit.name}", '
          'falling back to inexact delivery',
          error: e,
          stackTrace: st,
          name: 'NotificationService',
        );
        await fire(AndroidScheduleMode.inexactAllowWhileIdle);
        print(
          '[NotificationService] Used inexactAllowWhileIdle (fallback) for '
          '"${habit.name}"',
        );
      }
    } catch (e, st) {
      print(
        '[NotificationService] Failed to schedule reminder for '
        '"${habit.name}": $e',
      );
      developer.log(
        'Failed to schedule reminder for habit "${habit.name}"',
        error: e,
        stackTrace: st,
        name: 'NotificationService',
      );
    }
  }

  Future<void> cancelHabitReminder(String habitId) async {
    if (!supportsNotifications) return;
    try {
      await _plugin.cancel(_habitNotificationId(habitId));
    } catch (e, st) {
      developer.log(
        'Failed to cancel reminder for habit id "$habitId"',
        error: e,
        stackTrace: st,
        name: 'NotificationService',
      );
    }
  }
}

// =============================================================================
// APP ENTRY POINT
// =============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load the saved theme preference before the first frame so there's no
  // light->dark flash on startup.
  final prefs = await SharedPreferences.getInstance();
  themeModeNotifier.value = (prefs.getBool(_kIsDarkModeKey) ?? false)
      ? ThemeMode.dark
      : ThemeMode.light;

  // Web is tracking-only: the notification stack is never initialized there
  // (init() is also a no-op on web internally — this outer guard just makes
  // the startup path obvious and keeps web startup free of native-only
  // plugin calls entirely).
  if (!kIsWeb) {
    await NotificationService.instance.init();
  }

  // Per-habit reminders are re-scheduled from HabitsListScreen once the
  // habit list loads (see _loadHabits), as a safety net in addition to the
  // boot receiver.

  runApp(const HabitTrackerApp());
}

class HabitTrackerApp extends StatelessWidget {
  const HabitTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Multi-Habit Tracker',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            colorSchemeSeed: Colors.teal,
            // Apple's standard system background — soft off-white so pure
            // white cards read as distinct, elevated surfaces on top of it.
            scaffoldBackgroundColor: const Color(0xFFF2F2F7),
            cardColor: Colors.white,
            splashFactory: NoSplash.splashFactory,
            appBarTheme: const AppBarTheme(
              elevation: 0,
              centerTitle: true,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              titleTextStyle: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: Color(0xFF1C1C1E),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            dialogTheme: DialogThemeData(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              titleTextStyle: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1C1C1E),
              ),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorSchemeSeed: Colors.teal,
            scaffoldBackgroundColor: const Color(0xFF121212),
            cardColor: const Color(0xFF1E1E1E),
            splashFactory: NoSplash.splashFactory,
            appBarTheme: const AppBarTheme(
              elevation: 0,
              centerTitle: true,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              titleTextStyle: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: Colors.white,
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            dialogTheme: DialogThemeData(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              titleTextStyle: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          home: const HabitsListScreen(),
        );
      },
    );
  }
}

// =============================================================================
// THEME-AWARE COLOR HELPERS
// Centralizing these means every screen reads colors the same way, so
// dark mode stays visually consistent everywhere instead of screen-by-screen.
// =============================================================================

bool isDark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
Color onSurface(BuildContext c) => Theme.of(c).colorScheme.onSurface;
Color onSurfaceFaded(BuildContext c, double opacity) =>
    onSurface(c).withValues(alpha: opacity);
Color cardBg(BuildContext c) => Theme.of(c).cardColor;

// The habit palette mixes light pastels with dark premium tones, so any text
// drawn directly on top of a habit color needs to pick its contrast per
// swatch rather than assuming a light background.
Color contrastingTextColor(Color background) =>
    background.computeLuminance() < 0.5 ? Colors.white : Colors.black87;

// Calendar cell shades that keep enough contrast in both themes.
Color futureDayColor(BuildContext c) =>
    isDark(c) ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5);
Color pastUntrackedColor(BuildContext c) =>
    isDark(c) ? const Color(0xFF4A4A4A) : const Color(0xFFBDBDBD);
const Color kBrokenColor = Color(0xFFE57373); // red, same in both themes
const Color kGoalReachedColor = Color(
  0xFFFFB300,
); // gold/amber, same in both themes

// =============================================================================
// SHARED DATE HELPERS
// =============================================================================

String fmtDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

// =============================================================================
// MODELS
// =============================================================================

class Habit {
  String id;
  String name;
  int colorValue; // Color.value of the chosen theme color
  DateTime? startDate; // null = not currently tracking
  int goalDays;
  List<String> failedDates; // yyyy-MM-dd strings
  int? reminderHour; // null = no reminder set for this habit
  int? reminderMinute;
  Map<String, int> dayColors; // yyyy-MM-dd -> Color.toARGB32()
  Map<String, String> dayNotes; // yyyy-MM-dd -> free-text note

  Habit({
    required this.id,
    required this.name,
    required this.colorValue,
    this.startDate,
    this.goalDays = 30,
    List<String>? failedDates,
    this.reminderHour,
    this.reminderMinute,
    Map<String, int>? dayColors,
    Map<String, String>? dayNotes,
  })  : failedDates = failedDates ?? [],
        dayColors = dayColors ?? {},
        dayNotes = dayNotes ?? {};

  Color get color => Color(colorValue);

  TimeOfDay? get reminderTime =>
      (reminderHour != null && reminderMinute != null)
          ? TimeOfDay(hour: reminderHour!, minute: reminderMinute!)
          : null;

  /// Flexible "calendar/diary" streak: total days since startDate (inclusive
  /// of the start day, counted as day 1) minus any days in that same range
  /// that were marked missed. A single missed day only costs one day instead
  /// of resetting the whole streak to 0. Computed live — no timers involved.
  int get currentStreak {
    if (startDate == null) return 0;
    final today = dateOnly(DateTime.now());
    final start = dateOnly(startDate!);
    final diff = today.difference(start).inDays;
    if (diff < 0) return 0;
    final totalDays = diff + 1;
    final missedDays = failedDates.where((s) {
      DateTime parsed;
      try {
        parsed = DateTime.parse(s);
      } catch (e, st) {
        // A malformed entry (e.g. from manually edited local storage)
        // shouldn't crash the whole streak calculation — just skip it.
        developer.log(
          'Skipping malformed failedDates entry: "$s"',
          error: e,
          stackTrace: st,
          name: 'Habit',
        );
        return false;
      }
      final d = dateOnly(parsed);
      return !d.isBefore(start) && !d.isAfter(today);
    }).length;
    final streak = totalDays - missedDays;
    return streak < 0 ? 0 : streak;
  }

  /// True once an active streak has met or passed its goal.
  bool get goalReached => startDate != null && currentStreak >= goalDays;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'colorValue': colorValue,
        'startDate': startDate?.toIso8601String(),
        'goalDays': goalDays,
        'failedDates': failedDates,
        'reminderHour': reminderHour,
        'reminderMinute': reminderMinute,
        'dayColors': dayColors,
        'dayNotes': dayNotes,
      };

  factory Habit.fromJson(Map<String, dynamic> json) => Habit(
        id: json['id'] as String,
        name: json['name'] as String,
        colorValue: json['colorValue'] as int,
        startDate: json['startDate'] != null
            ? DateTime.parse(json['startDate'] as String)
            : null,
        goalDays: json['goalDays'] as int,
        failedDates: List<String>.from(json['failedDates'] as List),
        // Absent in habits saved before per-habit reminders existed —
        // treated as "no reminder set", same as a freshly created habit.
        reminderHour: json['reminderHour'] as int?,
        reminderMinute: json['reminderMinute'] as int?,
        // Absent in habits saved before per-day colors/notes existed —
        // treated as empty maps, same as a freshly created habit.
        dayColors: json['dayColors'] != null
            ? Map<String, int>.from(json['dayColors'] as Map)
            : null,
        dayNotes: json['dayNotes'] != null
            ? Map<String, String>.from(json['dayNotes'] as Map)
            : null,
      );
}

class TodoTask {
  String id;
  String title;
  bool isCompleted;

  TodoTask({required this.id, required this.title, this.isCompleted = false});

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'isCompleted': isCompleted,
      };

  factory TodoTask.fromJson(Map<String, dynamic> json) => TodoTask(
        id: json['id'] as String,
        title: json['title'] as String,
        isCompleted: json['isCompleted'] as bool,
      );
}

const List<Color> kHabitPalette = [
  // Row 1: Bright Pastels (Smooth, high-lightness gradient)
  Color(0xFFFFB3B3), // Pastel Pink
  Color(0xFFFFD9B3), // Pastel Peach
  Color(0xFFFFF2B3), // Pastel Yellow
  Color(0xFFD9FFB3), // Pastel Mint
  Color(0xFFB3FFFF), // Pastel Teal

  // Row 2: Cool Pastels bridging into Warm Muted colors
  Color(0xFFB3D9FF), // Pastel Sky Blue
  Color(0xFFD9B3FF), // Pastel Lavender
  Color(0xFFB5838D), // Mauve
  Color(0xFFF4A261), // Soft Coral
  Color(0xFFE9C46A), // Mustard

  // Row 3: Earthy & Deep Cool (Consistent muted lightness)
  Color(0xFFD5BDAF), // Warm Sand
  Color(0xFFA3B18A), // Matcha Green
  Color(0xFF7393B3), // Dusty Blue
  Color(0xFF5F7192), // Soft Indigo
  Color(0xFF708090), // Slate Grey
];

class _ColorPicker extends StatelessWidget {
  final Color selected;
  final ValueChanged<Color> onSelected;

  const _ColorPicker({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: kHabitPalette.map((c) {
        final isSelected = c.toARGB32() == selected.toARGB32();
        return GestureDetector(
          onTap: () => onSelected(c),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: isSelected
                  ? Border.all(color: Colors.black87, width: 3)
                  : Border.all(color: Colors.black12, width: 1),
            ),
            child: isSelected
                ? const Icon(Icons.check, size: 18, color: Colors.black54)
                : null,
          ),
        );
      }).toList(),
    );
  }
}

// =============================================================================
// A. HABITS LIST SCREEN (Home Screen)
// =============================================================================

class HabitsListScreen extends StatefulWidget {
  const HabitsListScreen({super.key});

  @override
  State<HabitsListScreen> createState() => _HabitsListScreenState();
}

class _HabitsListScreenState extends State<HabitsListScreen>
    with WidgetsBindingObserver {
  static const _kHabitsKey = 'habits_list';

  List<Habit> _habits = [];
  bool _isLoading = true;

  // null = not checked yet. Only meaningful on Android; other platforms
  // don't have this restriction, so the banner never applies there.
  bool? _exactAlarmGranted;
  bool _reminderBannerDismissed = false;

  bool get _anyHabitHasReminder => _habits.any((h) => h.reminderTime != null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadHabits();
    _checkExactAlarmPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check when the user comes back from Settings (or anywhere else),
    // so the banner disappears immediately after granting the permission
    // instead of requiring an app restart.
    if (state == AppLifecycleState.resumed) {
      _checkExactAlarmPermission();
    }
  }

  Future<void> _checkExactAlarmPermission() async {
    // This is an Android-only concept (exact alarms as a special-access
    // permission). Using dart:io's Platform here would break web
    // compilation, since this app also ships as a web PWA — foundation's
    // defaultTargetPlatform/kIsWeb are web-safe.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final status = await Permission.scheduleExactAlarm.status;
      if (!mounted) return;
      setState(() => _exactAlarmGranted = status.isGranted);
    } catch (e, st) {
      developer.log(
        'Failed to check exact-alarm permission status',
        error: e,
        stackTrace: st,
        name: 'HabitsListScreen',
      );
    }
  }

  Future<void> _requestExactAlarmPermission() async {
    try {
      // On Android this jumps straight to the "Alarms & reminders" system
      // settings screen for this app — there is no in-app runtime dialog
      // for this particular permission.
      await Permission.scheduleExactAlarm.request();
    } catch (e, st) {
      developer.log(
        'Failed to request exact-alarm permission',
        error: e,
        stackTrace: st,
        name: 'HabitsListScreen',
      );
    }
    // Covers the case where the status is already resolvable without
    // waiting for the app-resumed lifecycle callback.
    await _checkExactAlarmPermission();
  }

  // Amber warning accent for this banner only — distinct from kBrokenColor
  // (destructive actions) and kGoalReachedColor (celebration), so it doesn't
  // borrow the visual meaning of either.
  static const Color _kReminderWarningColor = Color(0xFFFF9F43);

  Widget? _buildExactAlarmBanner(BuildContext context) {
    if (_exactAlarmGranted != false) return null;
    if (_reminderBannerDismissed) return null;
    if (!_anyHabitHasReminder) return null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _kReminderWarningColor.withValues(
            alpha: isDark(context) ? 0.16 : 0.12,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _kReminderWarningColor.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              CupertinoIcons.bell_slash,
              color: _kReminderWarningColor,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reminders need one more permission to fire reliably',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: onSurface(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tap Enable to allow exact alarms in Settings.',
                    style: TextStyle(
                      fontSize: 13,
                      color: onSurfaceFaded(context, 0.7),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _requestExactAlarmPermission,
                      child: const Text('Enable'),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(CupertinoIcons.xmark, size: 18),
              onPressed: () => setState(() => _reminderBannerDismissed = true),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadHabits() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kHabitsKey);
    List<Habit> loaded = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        loaded = decoded
            .map((e) => Habit.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e, st) {
        // Corrupted or unreadable data — fall back to an empty list instead
        // of crashing on startup.
        developer.log(
          'Failed to parse saved habits, resetting to empty list',
          error: e,
          stackTrace: st,
          name: 'HabitsListScreen',
        );
        loaded = [];
      }
    }
    setState(() {
      _habits = loaded;
      _isLoading = false;
    });

    // Re-arm every habit's reminder on each app open, as a safety net in
    // addition to the boot receiver (e.g. in case an OS update or force-stop
    // cleared previously scheduled alarms).
    for (final habit in loaded) {
      final reminderTime = habit.reminderTime;
      if (reminderTime != null) {
        await NotificationService.instance.scheduleHabitReminder(
          habit,
          reminderTime,
        );
      }
    }
  }

  Future<void> _saveHabits() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_habits.map((h) => h.toJson()).toList());
    await prefs.setString(_kHabitsKey, raw);
  }

  void _onHabitUpdated() {
    setState(() {});
    _saveHabits();
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final habit = _habits.removeAt(oldIndex);
      _habits.insert(newIndex, habit);
    });
    _saveHabits();
  }

  // ---------------- Dark mode toggle ----------------

  Future<void> _toggleDarkMode() async {
    final newMode = themeModeNotifier.value == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    themeModeNotifier.value = newMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kIsDarkModeKey, newMode == ThemeMode.dark);
  }

  // ---------------- Per-habit reminder picker (shared by Add/Edit) ----------------

  Widget _reminderPickerRow({
    required BuildContext ctx,
    required TimeOfDay? time,
    required ValueChanged<TimeOfDay?> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () async {
              final picked = await showTimePicker(
                context: ctx,
                initialTime: time ?? const TimeOfDay(hour: 9, minute: 0),
                helpText: 'Habit reminder time',
              );
              if (picked != null) onChanged(picked);
            },
            icon: const Icon(CupertinoIcons.bell),
            label: Text(
              time == null
                  ? 'Set a reminder time'
                  : 'Remind me at ${time.format(ctx)}',
            ),
          ),
        ),
        if (time != null)
          IconButton(
            tooltip: 'Remove reminder',
            icon: const Icon(CupertinoIcons.clear_circled),
            onPressed: () => onChanged(null),
          ),
      ],
    );
  }

  // ---------------- Add habit ----------------

  Future<void> _addHabit() async {
    final nameController = TextEditingController();
    Color selectedColor = kHabitPalette.first;
    TimeOfDay? reminderTime;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add New Habit'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Reading',
                    labelText: 'Habit name',
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Theme color',
                  style: TextStyle(color: onSurfaceFaded(ctx, 0.6)),
                ),
                const SizedBox(height: 8),
                _ColorPicker(
                  selected: selectedColor,
                  onSelected: (c) => setDialogState(() => selectedColor = c),
                ),
                // Reminders don't exist on web (no plugin support, and iOS
                // Safari can't schedule local notifications) — offering the
                // picker there would be a broken promise. The model still
                // carries reminderHour/Minute so habits created on Android
                // keep their reminder data intact through a web session.
                if (!kIsWeb) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Daily reminder (optional)',
                    style: TextStyle(color: onSurfaceFaded(ctx, 0.6)),
                  ),
                  const SizedBox(height: 8),
                  _reminderPickerRow(
                    ctx: ctx,
                    time: reminderTime,
                    onChanged: (t) => setDialogState(() => reminderTime = t),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty) return;
                Navigator.pop(ctx, {
                  'name': nameController.text.trim(),
                  'color': selectedColor,
                  'reminderTime': reminderTime,
                });
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      final reminderTime = result['reminderTime'] as TimeOfDay?;
      final newHabit = Habit(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: result['name'] as String,
        colorValue: (result['color'] as Color).toARGB32(),
        reminderHour: reminderTime?.hour,
        reminderMinute: reminderTime?.minute,
      );
      setState(() => _habits.add(newHabit));
      await _saveHabits();
      if (reminderTime != null) {
        await NotificationService.instance.scheduleHabitReminder(
          newHabit,
          reminderTime,
        );
      }
    }
  }

  // ---------------- Edit habit ----------------

  Future<void> _editHabit(Habit habit) async {
    final nameController = TextEditingController(text: habit.name);
    final goalController = TextEditingController(
      text: habit.goalDays.toString(),
    );
    Color selectedColor = habit.color;
    TimeOfDay? reminderTime = habit.reminderTime;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Edit Habit'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Habit name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: goalController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Goal (days)'),
                ),
                const SizedBox(height: 16),
                Text(
                  'Theme color',
                  style: TextStyle(color: onSurfaceFaded(ctx, 0.6)),
                ),
                const SizedBox(height: 8),
                _ColorPicker(
                  selected: selectedColor,
                  onSelected: (c) => setDialogState(() => selectedColor = c),
                ),
                // Reminders don't exist on web (no plugin support, and iOS
                // Safari can't schedule local notifications) — offering the
                // picker there would be a broken promise. The model still
                // carries reminderHour/Minute so habits created on Android
                // keep their reminder data intact through a web session.
                if (!kIsWeb) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Daily reminder (optional)',
                    style: TextStyle(color: onSurfaceFaded(ctx, 0.6)),
                  ),
                  const SizedBox(height: 8),
                  _reminderPickerRow(
                    ctx: ctx,
                    time: reminderTime,
                    onChanged: (t) => setDialogState(() => reminderTime = t),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty) return;
                final goal =
                    int.tryParse(goalController.text) ?? habit.goalDays;
                Navigator.pop(ctx, {
                  'name': nameController.text.trim(),
                  'goal': goal > 0 ? goal : habit.goalDays,
                  'color': selectedColor,
                  'reminderTime': reminderTime,
                });
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      final newReminderTime = result['reminderTime'] as TimeOfDay?;
      setState(() {
        habit.name = result['name'] as String;
        habit.goalDays = result['goal'] as int;
        habit.colorValue = (result['color'] as Color).toARGB32();
        habit.reminderHour = newReminderTime?.hour;
        habit.reminderMinute = newReminderTime?.minute;
      });
      await _saveHabits();
      if (newReminderTime != null) {
        await NotificationService.instance.scheduleHabitReminder(
          habit,
          newReminderTime,
        );
      } else {
        await NotificationService.instance.cancelHabitReminder(habit.id);
      }
    }
  }

  // ---------------- Delete habit ----------------

  Future<void> _deleteHabit(Habit habit) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Habit?'),
        content: Text(
          'This will permanently delete "${habit.name}" and all of its '
          'tracking history. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kBrokenColor),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _habits.remove(habit));
      await _saveHabits();
      await NotificationService.instance.cancelHabitReminder(habit.id);
    }
  }

  void _showHabitOptions(Habit habit) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: onSurfaceFaded(ctx, 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.pencil),
              title: const Text('Edit Habit'),
              onTap: () {
                Navigator.pop(ctx);
                _editHabit(habit);
              },
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.trash, color: kBrokenColor),
              title: const Text(
                'Delete Habit',
                style: TextStyle(color: kBrokenColor),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _deleteHabit(habit);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openHabitDetail(Habit habit) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            HabitDetailScreen(habit: habit, onHabitUpdated: _onHabitUpdated),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final reminderBanner = _buildExactAlarmBanner(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Habits'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: onSurface(context),
        actions: [
          // FEATURE: dark/light mode toggle.
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) => IconButton(
              icon: Icon(
                mode == ThemeMode.dark
                    ? CupertinoIcons.sun_max_fill
                    : CupertinoIcons.moon_fill,
              ),
              tooltip: 'Toggle dark mode',
              onPressed: _toggleDarkMode,
            ),
          ),
          IconButton(
            icon: const Icon(CupertinoIcons.square_list),
            tooltip: 'To-Do List',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TodoScreen()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (reminderBanner != null) reminderBanner,
            Expanded(
              child: _habits.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.square_list,
                              size: 72,
                              color: onSurfaceFaded(context, 0.18),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              "No habits yet.\nLet's build something great!",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                height: 1.4,
                                color: onSurfaceFaded(context, 0.45),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _habits.length,
                      onReorder: _onReorder,
                      itemBuilder: (context, index) {
                        final habit = _habits[index];
                        return _HabitCard(
                          key: ValueKey(habit.id),
                          habit: habit,
                          index: index,
                          onTap: () => _openHabitDetail(habit),
                          onLongPress: () => _showHabitOptions(habit),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addHabit,
        icon: const Icon(CupertinoIcons.add),
        label: const Text('Add New Habit'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }
}

// A single card in the habits list — minimalist card with a soft shadow and
// a colored accent strip reflecting the habit's theme color. Tap opens the
// tracker; long-press opens the edit/delete bottom sheet; the drag handle
// (isolated from the InkWell via ReorderableDragStartListener) reorders it.
class _HabitCard extends StatelessWidget {
  final Habit habit;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _HabitCard({
    super.key,
    required this.habit,
    required this.index,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 20,
                spreadRadius: 0,
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(20),
                  ),
                  onTap: onTap,
                  onLongPress: onLongPress,
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 76,
                        decoration: BoxDecoration(
                          color: habit.color,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(20),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    habit.name,
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                      color: onSurface(context),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Goal: ${habit.goalDays} days',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: onSurfaceFaded(context, 0.6),
                                    ),
                                  ),
                                  if (habit.goalReached) ...[
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Goal Reached!',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: kGoalReachedColor,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    '${habit.currentStreak}',
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      color: onSurface(context),
                                    ),
                                  ),
                                  Text(
                                    'day streak',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: onSurfaceFaded(context, 0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 24,
                  ),
                  child: Icon(
                    CupertinoIcons.line_horizontal_3,
                    color: onSurfaceFaded(context, 0.35),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// B. HABIT DETAIL SCREEN (The Tracker)
// =============================================================================

class HabitDetailScreen extends StatefulWidget {
  final Habit habit;
  final VoidCallback onHabitUpdated;

  const HabitDetailScreen({
    super.key,
    required this.habit,
    required this.onHabitUpdated,
  });

  @override
  State<HabitDetailScreen> createState() => _HabitDetailScreenState();
}

class _HabitDetailScreenState extends State<HabitDetailScreen> {
  late DateTime _visibleMonth;

  Habit get habit => widget.habit;

  @override
  void initState() {
    super.initState();
    _visibleMonth = DateTime(DateTime.now().year, DateTime.now().month);
  }

  bool get _alreadyMarkedMissedToday =>
      habit.failedDates.contains(fmtDate(dateOnly(DateTime.now())));

  void _startCount() {
    setState(() => habit.startDate = dateOnly(DateTime.now()));
    widget.onHabitUpdated();
  }

  /// Toggles a day's missed state. Marking is now trivially reversible
  /// (tap again to undo), so there is no confirmation dialog — a SnackBar
  /// gives feedback instead, which is enough for a two-way action.
  void _toggleMissedFor(DateTime day) {
    final key = fmtDate(dateOnly(day));
    final wasMissed = habit.failedDates.contains(key);
    setState(() {
      if (wasMissed) {
        habit.failedDates.remove(key);
      } else {
        habit.failedDates.add(key);
      }
    });
    widget.onHabitUpdated();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
            wasMissed
                ? 'Un-marked $key — no longer counted as missed.'
                : 'Marked $key as missed. Tap the day again to undo.',
          ),
        ),
      );
  }

  /// Long-press options for a single day. Ordered by how often each is
  /// used: note first (prominent, no scrolling needed), missed switch, and
  /// the color palette last, collapsed behind an expandable row since it's
  /// the least-used control and the tallest.
  Future<void> _showDayOptions(DateTime day) async {
    final key = fmtDate(dateOnly(day));
    final noteController = TextEditingController(
      text: habit.dayNotes[key] ?? '',
    );
    bool colorExpanded = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final isMissed = habit.failedDates.contains(key);
          final customColorValue = habit.dayColors[key];
          return Padding(
            // Keep the note field visible above the keyboard.
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: onSurfaceFaded(ctx, 0.15),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          key,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: onSurface(ctx),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Note',
                        style: TextStyle(color: onSurfaceFaded(ctx, 0.6)),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: noteController,
                        maxLines: 3,
                        minLines: 1,
                        decoration: const InputDecoration(
                          hintText: 'Write a note for this day...',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (habit.dayNotes.containsKey(key))
                            TextButton(
                              onPressed: () {
                                setState(() => habit.dayNotes.remove(key));
                                widget.onHabitUpdated();
                                noteController.clear();
                                setSheetState(() {});
                              },
                              child: const Text(
                                'Delete note',
                                style: TextStyle(color: kBrokenColor),
                              ),
                            ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
                              final text = noteController.text.trim();
                              setState(() {
                                if (text.isEmpty) {
                                  habit.dayNotes.remove(key);
                                } else {
                                  habit.dayNotes[key] = text;
                                }
                              });
                              widget.onHabitUpdated();
                              Navigator.pop(ctx);
                            },
                            child: const Text('Save'),
                          ),
                        ],
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Marked as missed'),
                        activeThumbColor: kBrokenColor,
                        value: isMissed,
                        onChanged: (_) {
                          _toggleMissedFor(day);
                          setSheetState(() {});
                        },
                      ),
                      // Collapsible color section: the header row shows the
                      // current swatch so the state is visible even while
                      // the palette itself stays folded away.
                      InkWell(
                        onTap: () => setSheetState(
                          () => colorExpanded = !colorExpanded,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              Text(
                                'Day color',
                                style: TextStyle(
                                  color: onSurfaceFaded(ctx, 0.6),
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (customColorValue != null)
                                Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    color: Color(customColorValue),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: onSurfaceFaded(ctx, 0.2),
                                    ),
                                  ),
                                ),
                              const Spacer(),
                              Icon(
                                colorExpanded
                                    ? CupertinoIcons.chevron_up
                                    : CupertinoIcons.chevron_down,
                                size: 16,
                                color: onSurfaceFaded(ctx, 0.5),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (colorExpanded) ...[
                        const SizedBox(height: 4),
                        _ColorPicker(
                          // 0x00000000 matches no palette entry, so nothing
                          // renders as selected when no custom color is set.
                          selected: customColorValue != null
                              ? Color(customColorValue)
                              : const Color(0x00000000),
                          onSelected: (c) {
                            setState(
                              () => habit.dayColors[key] = c.toARGB32(),
                            );
                            widget.onHabitUpdated();
                            setSheetState(() {});
                          },
                        ),
                        if (customColorValue != null)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () {
                                setState(() => habit.dayColors.remove(key));
                                widget.onHabitUpdated();
                                setSheetState(() {});
                              },
                              child: const Text('Remove color'),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    // The sheet mutates habit state as the user interacts; make sure the
    // calendar underneath reflects the final state once it closes.
    if (mounted) setState(() {});
  }

  /// Tap target for a day that has a note: a lightweight read popup. It
  /// must still offer the missed toggle — tapping a noted day no longer
  /// toggles missed directly, so without this button a noted day would be
  /// an undo dead end (the exact trap this feature set exists to fix).
  Future<void> _showNotePopup(DateTime day) async {
    final key = fmtDate(dateOnly(day));
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isMissed = habit.failedDates.contains(key);
          return AlertDialog(
            title: Text(key),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Text(
                  habit.dayNotes[key] ?? '',
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    color: onSurface(ctx),
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _toggleMissedFor(day);
                  setDialogState(() {});
                },
                child: Text(
                  isMissed ? 'Unmark as missed' : 'Mark as missed',
                  style: const TextStyle(color: kBrokenColor),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showDayOptions(day);
                },
                child: const Text('Edit'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _editGoal() async {
    final controller = TextEditingController(text: habit.goalDays.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Your Goal'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(suffixText: 'days'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final val = int.tryParse(controller.text);
              Navigator.pop(
                ctx,
                (val != null && val > 0) ? val : habit.goalDays,
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) {
      setState(() => habit.goalDays = result);
      widget.onHabitUpdated();
    }
  }

  // Cell color precedence, highest first:
  //  1. Custom day color — the user's explicit choice always wins. (A day
  //     that is also missed keeps a small red corner dot so the missed
  //     state can't be accidentally hidden; see _buildCalendar.)
  //  2. Red (kBrokenColor) — day is in the failed/missed list.
  //  3. Habit theme color — day is between startDate and today while active.
  //  4. Dark gray — past day that was neither tracked nor failed.
  //     Light gray — future day (hasn't happened yet).
  Color _colorForDay(BuildContext context, DateTime day) {
    final normalized = dateOnly(day);
    final today = dateOnly(DateTime.now());
    final key = fmtDate(normalized);

    final customColor = habit.dayColors[key];
    if (customColor != null) return Color(customColor);

    if (habit.failedDates.contains(key)) return kBrokenColor;

    if (habit.startDate != null) {
      final start = dateOnly(habit.startDate!);
      if (!normalized.isBefore(start) && !normalized.isAfter(today)) {
        return habit.color;
      }
    }

    if (normalized.isAfter(today)) return futureDayColor(context);
    return pastUntrackedColor(context);
  }

  @override
  Widget build(BuildContext context) {
    final isActive = habit.startDate != null;
    // Three button states: start tracking, mark today missed (red), or undo
    // today's missed mark (back to the habit color — a restorative action).
    final missedToday = _alreadyMarkedMissedToday;
    final actionButtonColor =
        (isActive && !missedToday) ? kBrokenColor : habit.color;

    return Scaffold(
      appBar: AppBar(
        title: Text('Day Tracker For: ${habit.name}'),
        elevation: 0,
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: onSurface(context),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            children: [
              GestureDetector(
                onTap: _editGoal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Goal: ${habit.goalDays} Days',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        color: onSurfaceFaded(context, 0.6),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      CupertinoIcons.pencil,
                      size: 16,
                      color: onSurfaceFaded(context, 0.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '${habit.currentStreak}',
                    style: TextStyle(
                      fontSize: 96,
                      fontWeight: FontWeight.bold,
                      color:
                          habit.goalReached ? kGoalReachedColor : habit.color,
                      height: 1.0,
                    ),
                  ),
                  if (habit.goalReached) ...[
                    const SizedBox(width: 8),
                    const Icon(
                      CupertinoIcons.rosette,
                      color: kGoalReachedColor,
                      size: 36,
                    ),
                  ],
                ],
              ),
              Text(
                habit.goalReached
                    ? 'Goal reached!'
                    : (isActive ? 'days tracked' : 'not started'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight:
                      habit.goalReached ? FontWeight.w600 : FontWeight.w400,
                  color: habit.goalReached
                      ? kGoalReachedColor
                      : onSurfaceFaded(context, 0.6),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: actionButtonColor,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: !isActive
                      ? _startCount
                      : () => _toggleMissedFor(DateTime.now()),
                  child: Text(
                    !isActive
                        ? 'Start Count'
                        : (missedToday ? 'Undo Missed Today' : 'Missed Today'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: contrastingTextColor(actionButtonColor),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              _buildCalendar(context),
              const SizedBox(height: 8),
              Text(
                'Tap a day to toggle missed (noted days open their note) • '
                'Long-press for all options',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: onSurfaceFaded(context, 0.5),
                ),
              ),
              const SizedBox(height: 12),
              _buildLegend(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCalendar(BuildContext context) {
    const monthNames = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final monthName = monthNames[_visibleMonth.month];

    final firstDayOfMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month,
      1,
    );
    final daysInMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + 1,
      0,
    ).day;
    final leadingBlanks = firstDayOfMonth.weekday % 7;
    final totalCells = leadingBlanks + daysInMonth;
    final trailingBlanks = (7 - (totalCells % 7)) % 7;

    final cells = <Widget>[];
    for (int i = 0; i < leadingBlanks; i++) {
      cells.add(const SizedBox.shrink());
    }
    final today = dateOnly(DateTime.now());
    for (int day = 1; day <= daysInMonth; day++) {
      final date = DateTime(_visibleMonth.year, _visibleMonth.month, day);
      final normalized = dateOnly(date);
      final key = fmtDate(normalized);
      final isToday = normalized == today;
      final isFuture = normalized.isAfter(today);
      final isMissed = habit.failedDates.contains(key);
      final hasCustomColor = habit.dayColors.containsKey(key);
      final hasNote = habit.dayNotes.containsKey(key);
      final cellColor = _colorForDay(context, date);
      final textColor = contrastingTextColor(cellColor);

      final cell = Container(
        decoration: BoxDecoration(
          color: cellColor,
          border: Border.all(
            color: Theme.of(context).scaffoldBackgroundColor,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              '$day',
              style: TextStyle(
                fontSize: 13,
                fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
                color: textColor,
                decoration: isToday ? TextDecoration.underline : null,
              ),
            ),
            // A custom color takes over the cell background, so a missed
            // day would otherwise become invisible — keep it flagged with
            // a red corner dot (ringed for contrast on reddish swatches).
            if (isMissed && hasCustomColor)
              Positioned(
                top: 2,
                right: 2,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: kBrokenColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: textColor, width: 1),
                  ),
                ),
              ),
            // Note indicator: contrast-derived dot so it reads against
            // every palette swatch in both themes.
            if (hasNote)
              Positioned(
                bottom: 2,
                right: 2,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: textColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      );

      cells.add(
        // Future days are inert: they can't be missed, colored, or
        // annotated — they haven't happened yet. For past/today cells the
        // tap is state-dependent: a noted day opens its note for reading
        // (never silently toggling missed); a plain day toggles missed.
        isFuture
            ? cell
            : GestureDetector(
                onTap: hasNote
                    ? () => _showNotePopup(date)
                    : () => _toggleMissedFor(date),
                onLongPress: () => _showDayOptions(date),
                child: cell,
              ),
      );
    }
    for (int i = 0; i < trailingBlanks; i++) {
      cells.add(const SizedBox.shrink());
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 20,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(CupertinoIcons.chevron_left),
                onPressed: () => setState(() {
                  _visibleMonth = DateTime(
                    _visibleMonth.year,
                    _visibleMonth.month - 1,
                  );
                }),
              ),
              Text(
                '$monthName ${_visibleMonth.year}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: onSurface(context),
                ),
              ),
              IconButton(
                icon: const Icon(CupertinoIcons.chevron_right),
                onPressed: () => setState(() {
                  _visibleMonth = DateTime(
                    _visibleMonth.year,
                    _visibleMonth.month + 1,
                  );
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: ['S', 'M', 'T', 'W', 'T', 'F', 'S']
                .map(
                  (d) => Expanded(
                    child: Text(
                      d,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: onSurfaceFaded(context, 0.5),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            childAspectRatio: 1,
            children: cells,
          ),
        ],
      ),
    );
  }

  Widget _buildLegend(BuildContext context) {
    Widget dot(Color c) => Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: onSurfaceFaded(context, 0.15)),
          ),
        );
    Widget label(String text) => Text(
          text,
          style: TextStyle(fontSize: 12, color: onSurfaceFaded(context, 0.7)),
        );

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 14,
      runSpacing: 6,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dot(habit.color),
            const SizedBox(width: 6),
            label('Tracked'),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dot(kBrokenColor),
            const SizedBox(width: 6),
            label('Broken'),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dot(pastUntrackedColor(context)),
            const SizedBox(width: 6),
            label('Past (untracked)'),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dot(futureDayColor(context)),
            const SizedBox(width: 6),
            label('Future'),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// C. TO-DO LIST SCREEN (auto-sort: incomplete on top, completed at bottom)
// =============================================================================

class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key});

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> {
  static const _kTodosKey = 'todo_tasks_list';

  List<TodoTask> _todos = [];
  bool _isLoading = true;
  final TextEditingController _inputController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadTodos();
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _sortTodos() {
    _todos.sort((a, b) {
      if (a.isCompleted == b.isCompleted) return 0;
      return a.isCompleted ? 1 : -1;
    });
  }

  Future<void> _loadTodos() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kTodosKey);
    List<TodoTask> loaded = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        loaded = decoded
            .map((e) => TodoTask.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e, st) {
        // Corrupted or unreadable data — fall back to an empty list instead
        // of crashing on startup.
        developer.log(
          'Failed to parse saved todos, resetting to empty list',
          error: e,
          stackTrace: st,
          name: 'TodoScreen',
        );
        loaded = [];
      }
    }
    setState(() {
      _todos = loaded;
      _sortTodos();
      _isLoading = false;
    });
  }

  Future<void> _saveTodos() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(_todos.map((t) => t.toJson()).toList());
    await prefs.setString(_kTodosKey, raw);
  }

  void _addTodo() {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _todos.add(
        TodoTask(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          title: text,
        ),
      );
      _sortTodos();
      _inputController.clear();
    });
    _saveTodos();
  }

  void _toggleTodo(TodoTask task, bool? value) {
    setState(() {
      task.isCompleted = value ?? false;
      _sortTodos();
    });
    _saveTodos();
  }

  void _deleteTodo(TodoTask task) {
    setState(() => _todos.remove(task));
    _saveTodos();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('To-Do List'),
        elevation: 0,
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: onSurface(context),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      decoration: InputDecoration(
                        hintText: 'Add a new task...',
                        filled: true,
                        fillColor: cardBg(context),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      onSubmitted: (_) => _addTodo(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _addTodo,
                    child: const Icon(CupertinoIcons.add),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _todos.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.check_mark_circled,
                              size: 72,
                              color: onSurfaceFaded(context, 0.18),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              'All caught up!\nEnjoy your day.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                height: 1.4,
                                color: onSurfaceFaded(context, 0.45),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: _todos.length,
                      itemBuilder: (context, index) {
                        final task = _todos[index];
                        return Dismissible(
                          key: ValueKey(task.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            margin: const EdgeInsets.symmetric(
                              vertical: 6,
                              horizontal: 8,
                            ),
                            decoration: BoxDecoration(
                              color: kBrokenColor,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Icon(
                              CupertinoIcons.trash,
                              color: Colors.white,
                            ),
                          ),
                          onDismissed: (_) => _deleteTodo(task),
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                              vertical: 6,
                              horizontal: 8,
                            ),
                            decoration: BoxDecoration(
                              color: cardBg(context),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.04),
                                  blurRadius: 20,
                                  spreadRadius: 0,
                                ),
                              ],
                            ),
                            child: ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              leading: Checkbox(
                                value: task.isCompleted,
                                onChanged: (v) => _toggleTodo(task, v),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                              title: Text(
                                task.title,
                                style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  decoration: task.isCompleted
                                      ? TextDecoration.lineThrough
                                      : null,
                                  color: task.isCompleted
                                      ? onSurfaceFaded(context, 0.4)
                                      : onSurface(context),
                                ),
                              ),
                              trailing: IconButton(
                                icon: const Icon(CupertinoIcons.trash),
                                onPressed: () => _deleteTodo(task),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
