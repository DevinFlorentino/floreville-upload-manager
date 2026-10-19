import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/queue_summary.dart';
import '../models/upload_status.dart';
import '../models/upload_task.dart';
import 'notification_config.dart';

/// Single, throttled, aggregated notification for the whole queue.
///
/// While uploading: ongoing notification with a progress bar (Android) /
/// passive updates with a progress subtitle (iOS, macOS). When the queue
/// drains: a dismissible "complete", "failed" or "paused" notification —
/// only for activity that happened in this app session, so the user isn't
/// nagged at launch about yesterday's failures.
///
/// iOS/macOS cannot draw a progress bar in a notification; that is a
/// platform limit.
class UploadNotificationManager {
  UploadNotificationManager({
    this.config = const NotificationConfig(),
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin;

  final NotificationConfig config;
  FlutterLocalNotificationsPlugin? _plugin;

  bool _ready = false;
  bool _disposed = false;

  QueueSummary? _pendingSummary;
  UploadTask? _pendingFocus;
  String? _lastStateKey;
  DateTime _lastShown = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _throttle;

  bool _sessionActive = false;
  bool _startAlertPending = false;
  int _sessionStartCompleted = 0;
  int _sessionStartFailed = 0;
  UploadTask? _lastCompleted;

  static bool get _platformSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  bool get isReady => _ready;

  Future<void> init() async {
    if (!config.enabled || _ready || !_platformSupported) return;
    try {
      final plugin = _plugin ??= FlutterLocalNotificationsPlugin();
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await plugin.initialize(
        settings: InitializationSettings(
          android: AndroidInitializationSettings(config.androidIcon),
          iOS: darwin,
          macOS: darwin,
        ),
      );
      final android = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        AndroidNotificationChannel(
          config.channelId,
          config.channelName,
          description: config.channelDescription,
          importance: Importance.defaultImportance,
          playSound: false,
          enableVibration: false,
          showBadge: false,
        ),
      );
      _ready = true;
      if (config.requestPermissionOnInit) await requestPermission();
    } catch (e) {
      debugPrint('[floreville_upload_manager] Notification init failed: $e');
    }
  }

  /// Asks the OS for notification permission. Returns true if granted (or
  /// not applicable on this platform).
  Future<bool> requestPermission() async {
    if (!config.enabled || !_platformSupported) return false;
    final plugin = _plugin ??= FlutterLocalNotificationsPlugin();
    try {
      if (Platform.isAndroid) {
        return await plugin
                .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            false;
      }
      if (Platform.isIOS) {
        return await plugin
                .resolvePlatformSpecificImplementation<
                    IOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, badge: false, sound: true) ??
            false;
      }
      if (Platform.isMacOS) {
        return await plugin
                .resolvePlatformSpecificImplementation<
                    MacOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, badge: false, sound: true) ??
            false;
      }
    } catch (e) {
      debugPrint('[floreville_upload_manager] Permission request failed: $e');
    }
    return false;
  }

  /// Feed the latest queue state. Cheap to call often — renders are
  /// throttled except on state changes.
  void update(QueueSummary summary, {UploadTask? focus}) {
    if (!_ready || _disposed) return;
    _pendingSummary = summary;
    if (focus != null) _pendingFocus = focus;

    final changed = summary.stateKey != _lastStateKey;
    _lastStateKey = summary.stateKey;
    final elapsed = DateTime.now().difference(_lastShown);

    if (changed || elapsed >= config.throttleInterval) {
      _throttle?.cancel();
      _throttle = null;
      _flush();
    } else {
      _throttle ??= Timer(config.throttleInterval - elapsed, () {
        _throttle = null;
        _flush();
      });
    }
  }

  void _flush() {
    final summary = _pendingSummary;
    if (summary == null || _disposed) return;
    _lastShown = DateTime.now();
    unawaited(_render(summary, _pendingFocus));
  }

  Future<void> _render(QueueSummary s, UploadTask? focus) async {
    final plugin = _plugin;
    if (plugin == null) return;
    try {
      if (focus != null && focus.status == UploadStatus.completed) {
        _lastCompleted = focus;
      }
      final uploading = s.activeTasks > 0 || s.enqueuedTasks > 0;
      if (uploading && !_sessionActive) {
        _sessionActive = true;
        _startAlertPending = config.alertOnStart;
        _sessionStartCompleted = s.completedTasks;
        _sessionStartFailed = s.failedTasks;
        _lastCompleted = null;
      }
      if (!_sessionActive) return;

      String title;
      String body;
      String subtitle;
      int? progress;
      var alert = false;
      var ongoing = false;

      if (uploading) {
        ongoing = true;
        progress = s.overallProgressPercent;
        alert = _startAlertPending;
        _startAlertPending = false;
        title = config.titleBuilder?.call(focus, s) ?? _progressTitle(s, focus);
        body = config.bodyBuilder?.call(focus, s) ?? _progressBody(s, focus);
        subtitle = s.isConnected
            ? '$progress% • ${s.formattedSpeed}'
            : 'Waiting for network';
      } else {
        final newFailures = s.failedTasks - _sessionStartFailed;
        final newCompletions = s.completedTasks - _sessionStartCompleted;
        if (newFailures > 0) {
          alert = config.alertOnFailure;
          title = newFailures == 1
              ? 'Upload failed'
              : '$newFailures uploads failed';
          body = 'Open the app to retry.';
          subtitle = 'Upload failed';
        } else if (s.pausedTasks > 0) {
          title = 'Uploads paused';
          body = '${s.pausedTasks} paused — open the app to resume.';
          subtitle = 'Paused';
        } else if (newCompletions > 0) {
          alert = config.alertOnComplete;
          title = newCompletions == 1
              ? 'Upload complete'
              : '$newCompletions uploads complete';
          body = newCompletions == 1 && _lastCompleted != null
              ? '${_lastCompleted!.fileName} uploaded.'
              : 'All files uploaded.';
          subtitle = 'Complete';
        } else {
          // Everything was cancelled / cleared.
          _sessionActive = false;
          await plugin.cancel(id: config.notificationId);
          return;
        }
        _sessionActive = false;
      }

      final darwin = DarwinNotificationDetails(
        presentAlert: alert,
        presentBanner: alert,
        presentList: true,
        presentSound: alert && config.playSound,
        subtitle: subtitle,
        interruptionLevel:
            alert ? InterruptionLevel.active : InterruptionLevel.passive,
      );
      await plugin.show(
        id: config.notificationId,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            config.channelId,
            config.channelName,
            channelDescription: config.channelDescription,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            showProgress: progress != null,
            maxProgress: 100,
            progress: progress ?? 0,
            ongoing: ongoing,
            autoCancel: !ongoing,
            onlyAlertOnce: !alert,
            silent: !alert,
            playSound: alert && config.playSound,
          ),
          iOS: darwin,
          macOS: darwin,
        ),
      );
    } catch (e) {
      debugPrint('[floreville_upload_manager] Notification render failed: $e');
    }
  }

  static String _progressTitle(QueueSummary s, UploadTask? focus) {
    if (!s.isConnected) return 'Uploads waiting for network';
    final inFlight = s.totalActiveAndPending;
    if (inFlight == 1 && focus != null) return 'Uploading ${focus.fileName}';
    return 'Uploading $inFlight files';
  }

  static String _progressBody(QueueSummary s, UploadTask? focus) {
    final queued = s.enqueuedTasks > 0 ? ' • ${s.enqueuedTasks} queued' : '';
    return '${s.formattedUploadedSize} of ${s.formattedTotalSize} '
        '(${s.overallProgressPercent}%) • ${s.formattedSpeed}$queued';
  }

  Future<void> cancel() async {
    if (!_ready) return;
    try {
      await _plugin?.cancel(id: config.notificationId);
    } catch (_) {}
  }

  void dispose() {
    _disposed = true;
    _throttle?.cancel();
    _throttle = null;
  }
}
