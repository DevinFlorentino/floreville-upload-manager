import '../models/queue_summary.dart';
import '../models/upload_task.dart';

typedef NotificationTextBuilder = String Function(
  UploadTask? task,
  QueueSummary summary,
);

/// System-tray progress notification settings (Android, iOS, macOS).
class NotificationConfig {
  const NotificationConfig({
    this.enabled = true,
    this.channelId = 'floreville_uploads',
    this.channelName = 'Uploads',
    this.channelDescription = 'Progress of ongoing file uploads',
    this.androidIcon = '@mipmap/ic_launcher',
    this.notificationId = 98765,
    this.throttleInterval = const Duration(milliseconds: 750),
    this.alertOnStart = false,
    this.alertOnComplete = true,
    this.alertOnFailure = true,
    this.playSound = true,
    this.requestPermissionOnInit = false,
    this.titleBuilder,
    this.bodyBuilder,
  });

  /// Notifications off — in-app UI only.
  static const NotificationConfig disabled = NotificationConfig(enabled: false);

  final bool enabled;
  final String channelId;
  final String channelName;
  final String channelDescription;

  /// Android small icon resource, e.g. '@drawable/ic_upload' (should be a
  /// white-on-transparent monochrome icon for a clean status bar).
  final String androidIcon;

  final int notificationId;

  /// Minimum gap between progress refreshes. State changes (start, finish,
  /// failure, pause) are always shown immediately.
  final Duration throttleInterval;

  final bool alertOnStart;
  final bool alertOnComplete;
  final bool alertOnFailure;
  final bool playSound;

  /// Prompt for notification permission during `init()`. Off by default so
  /// your app can ask at a meaningful moment via
  /// `requestNotificationPermission()`.
  final bool requestPermissionOnInit;

  /// Override the title/body for the in-progress state.
  final NotificationTextBuilder? titleBuilder;
  final NotificationTextBuilder? bodyBuilder;
}
