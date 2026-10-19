/// Persistent, offline-tolerant upload queue for Flutter.
///
/// ```dart
/// await FlorevilleUploadManager.initialize(
///   headerProvider: (_) async => {'Authorization': 'Bearer ${await token()}'},
/// );
/// final task = await FlorevilleUploadManager.upload(
///   file: '/path/to/video.mp4',
///   url: 'https://api.example.com/uploads',
/// );
/// ```
library;

import 'dart:io';

import 'src/adapters/upload_adapter.dart';
import 'src/core/connectivity_monitor.dart';
import 'src/core/retry_policy.dart';
import 'src/core/upload_engine.dart';
import 'src/models/task_priority.dart';
import 'src/models/upload_protocol.dart';
import 'src/models/upload_task.dart';
import 'src/notifications/notification_config.dart';
import 'src/persistence/queue_storage.dart';

export 'src/adapters/resumable_adapter.dart';
export 'src/adapters/s3_multipart_adapter.dart';
export 'src/adapters/simulated_adapter.dart';
export 'src/adapters/standard_adapter.dart';
export 'src/adapters/upload_adapter.dart';
export 'src/core/connectivity_monitor.dart';
export 'src/core/retry_policy.dart';
export 'src/core/speed_tracker.dart';
export 'src/core/upload_engine.dart';
export 'src/core/upload_queue.dart';
export 'src/models/queue_summary.dart';
export 'src/models/task_priority.dart';
export 'src/models/upload_exception.dart';
export 'src/models/upload_protocol.dart';
export 'src/models/upload_status.dart';
export 'src/models/upload_task.dart';
export 'src/notifications/notification_config.dart';
export 'src/notifications/upload_notification_manager.dart';
export 'src/persistence/file_queue_storage.dart';
export 'src/persistence/in_memory_queue_storage.dart';
export 'src/persistence/queue_storage.dart';
export 'src/utils/http_utils.dart' show FileFingerprint, mimeTypeFor;
export 'src/widgets/upload_progress_bar.dart';
export 'src/widgets/upload_task_tile.dart';

/// App-wide entry point holding the shared [UploadEngine].
///
/// Call [initialize] once in `main()` (after
/// `WidgetsFlutterBinding.ensureInitialized()`). Accessing [instance] first
/// creates an engine with defaults.
abstract final class FlorevilleUploadManager {
  static UploadEngine? _instance;

  /// The shared engine.
  static UploadEngine get instance => _instance ??= UploadEngine();

  /// Whether the shared engine exists yet.
  static bool get hasInstance => _instance != null;

  /// Configures and starts the shared engine (restores the persisted queue
  /// and resumes interrupted uploads).
  ///
  /// [adapters] are registered in addition to the defaults (standard,
  /// resumable, simulated) — e.g. an `S3MultipartUploadAdapter`.
  ///
  /// Throws [StateError] if the shared engine was already created; configure
  /// before first use.
  static Future<UploadEngine> initialize({
    QueueStorage? storage,
    ConnectivityMonitor? connectivityMonitor,
    RetryPolicy retryPolicy = const RetryPolicy(),
    int maxConcurrentUploads = 2,
    HeaderProvider? headerProvider,
    NotificationConfig notificationConfig = const NotificationConfig(),
    List<UploadAdapter> adapters = const [],
  }) async {
    if (_instance != null) {
      throw StateError(
        'FlorevilleUploadManager is already initialized. Call initialize() once, '
        'before anything touches FlorevilleUploadManager.instance.',
      );
    }
    final engine = UploadEngine(
      storage: storage,
      connectivityMonitor: connectivityMonitor,
      retryPolicy: retryPolicy,
      maxConcurrentUploads: maxConcurrentUploads,
      headerProvider: headerProvider,
      notificationConfig: notificationConfig,
    )..registerAdapters(adapters);
    _instance = engine;
    await engine.init();
    return engine;
  }

  /// Disposes the shared engine (mainly for tests / sign-out flows).
  static Future<void> reset() async {
    final engine = _instance;
    _instance = null;
    await engine?.dispose();
  }

  /// Enqueue one file (a [File] or a path). Passing a `List` delegates to
  /// [uploadMultiple].
  static Future<UploadTask> upload({
    required Object file,
    required String url,
    UploadProtocol protocol = UploadProtocol.standard,
    String? customAdapterId,
    String method = 'POST',
    Map<String, String> headers = const {},
    Map<String, dynamic> data = const {},
    String fileFieldName = 'file',
    TaskPriority priority = TaskPriority.normal,
    String? tag,
    Map<String, dynamic> metadata = const {},
    int? maxRetries,
    int? simulatedFileSize,
    TaskProgressCallback? onProgress,
    TaskSuccessCallback? onSuccess,
    TaskErrorCallback? onError,
  }) {
    if (file is List) {
      return uploadMultiple(
        files: [
          for (final Object? f in file)
            if (f != null) f
        ],
        url: url,
        protocol: protocol,
        customAdapterId: customAdapterId,
        method: method,
        headers: headers,
        data: data,
        fileFieldName: fileFieldName == 'file' ? 'files' : fileFieldName,
        priority: priority,
        tag: tag,
        metadata: metadata,
        maxRetries: maxRetries,
        onProgress: onProgress,
        onSuccess: onSuccess,
        onError: onError,
      );
    }
    return instance.enqueue(
      filePaths: [_pathOf(file)],
      url: url,
      protocol: protocol,
      customAdapterId: customAdapterId,
      method: method,
      headers: headers,
      data: data,
      fileFieldName: fileFieldName,
      priority: priority,
      tag: tag,
      metadata: metadata,
      maxRetries: maxRetries,
      simulatedFileSize: simulatedFileSize,
      onProgress: onProgress,
      onSuccess: onSuccess,
      onError: onError,
    );
  }

  /// Enqueue several files sent together in ONE multipart request (all
  /// succeed or the whole bundle is retried). For independent uploads, call
  /// [upload] per file instead.
  static Future<UploadTask> uploadMultiple({
    required List<Object> files,
    required String url,
    UploadProtocol protocol = UploadProtocol.standard,
    String? customAdapterId,
    String method = 'POST',
    Map<String, String> headers = const {},
    Map<String, dynamic> data = const {},
    String fileFieldName = 'files',
    TaskPriority priority = TaskPriority.normal,
    String? tag,
    Map<String, dynamic> metadata = const {},
    int? maxRetries,
    int? simulatedFileSize,
    TaskProgressCallback? onProgress,
    TaskSuccessCallback? onSuccess,
    TaskErrorCallback? onError,
  }) {
    return instance.enqueue(
      filePaths: files.map(_pathOf).toList(),
      url: url,
      protocol: protocol,
      customAdapterId: customAdapterId,
      method: method,
      headers: headers,
      data: data,
      fileFieldName: fileFieldName,
      priority: priority,
      tag: tag,
      metadata: metadata,
      maxRetries: maxRetries,
      simulatedFileSize: simulatedFileSize,
      onProgress: onProgress,
      onSuccess: onSuccess,
      onError: onError,
    );
  }

  static String _pathOf(Object file) {
    if (file is File) return file.path;
    if (file is String) return file;
    throw ArgumentError.value(file, 'file', 'must be a File or a String path');
  }
}

/// `File('/path/x.pdf').upload(url: ...)`.
extension FlorevilleFileUpload on File {
  Future<UploadTask> upload({
    required String url,
    UploadProtocol protocol = UploadProtocol.standard,
    String method = 'POST',
    Map<String, String> headers = const {},
    Map<String, dynamic> data = const {},
    String fileFieldName = 'file',
    TaskPriority priority = TaskPriority.normal,
    String? tag,
    Map<String, dynamic> metadata = const {},
    int? maxRetries,
    TaskProgressCallback? onProgress,
    TaskSuccessCallback? onSuccess,
    TaskErrorCallback? onError,
  }) =>
      FlorevilleUploadManager.upload(
        file: this,
        url: url,
        protocol: protocol,
        method: method,
        headers: headers,
        data: data,
        fileFieldName: fileFieldName,
        priority: priority,
        tag: tag,
        metadata: metadata,
        maxRetries: maxRetries,
        onProgress: onProgress,
        onSuccess: onSuccess,
        onError: onError,
      );
}
