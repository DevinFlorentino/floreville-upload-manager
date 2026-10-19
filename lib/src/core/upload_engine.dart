import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../adapters/resumable_adapter.dart';
import '../adapters/simulated_adapter.dart';
import '../adapters/standard_adapter.dart';
import '../adapters/upload_adapter.dart';
import '../models/queue_summary.dart';
import '../models/task_priority.dart';
import '../models/upload_exception.dart';
import '../models/upload_protocol.dart';
import '../models/upload_status.dart';
import '../models/upload_task.dart';
import '../notifications/notification_config.dart';
import '../notifications/upload_notification_manager.dart';
import '../persistence/file_queue_storage.dart';
import '../persistence/queue_storage.dart';
import 'connectivity_monitor.dart';
import 'retry_policy.dart';
import 'speed_tracker.dart';
import 'upload_queue.dart';

/// Supplies headers right before each attempt — the place for auth tokens
/// (e.g. `Supabase.instance.client.auth.currentSession?.accessToken`).
/// Returned headers are merged over the task's own headers.
typedef HeaderProvider = Future<Map<String, String>> Function(UploadTask task);

typedef TaskProgressCallback = void Function(
  double progress,
  double bytesPerSecond,
  Duration? eta,
);
typedef TaskSuccessCallback = void Function(UploadTask task);
typedef TaskErrorCallback = void Function(UploadTask task, Object error);

/// Why an in-flight attempt was stopped on purpose (vs. failing).
enum _StopReason { paused, cancelled, deleted, offline, disposed }

class _Callbacks {
  _Callbacks(this.onProgress, this.onSuccess, this.onError);
  final TaskProgressCallback? onProgress;
  final TaskSuccessCallback? onSuccess;
  final TaskErrorCallback? onError;
}

/// The queue engine: persistence, scheduling, retries, connectivity,
/// progress and notifications.
///
/// Most apps use the `FlorevilleUploadManager` facade; create engines directly for
/// isolated queues (per account, per feature) or tests.
///
/// Lifecycle: `init()` (called implicitly by every operation) restores the
/// persisted queue, demotes tasks that were mid-upload when the app died
/// back to *enqueued*, re-arms pending retry timers and starts uploading.
///
/// Per-task callbacks live in memory only; after an app restart observe
/// [statusStream] / [watch] instead.
class UploadEngine {
  UploadEngine({
    QueueStorage? storage,
    ConnectivityMonitor? connectivityMonitor,
    this.retryPolicy = const RetryPolicy(),
    this.maxConcurrentUploads = 2,
    this.headerProvider,
    NotificationConfig notificationConfig = const NotificationConfig(),
    UploadNotificationManager? notificationManager,
    bool registerDefaultAdapters = true,
  })  : assert(maxConcurrentUploads > 0),
        storage = storage ?? FileQueueStorage(),
        connectivityMonitor =
            connectivityMonitor ?? DefaultConnectivityMonitor(),
        _ownsConnectivity = connectivityMonitor == null,
        notifications = notificationManager ??
            UploadNotificationManager(config: notificationConfig) {
    if (registerDefaultAdapters) {
      registerAdapter(StandardUploadAdapter());
      registerAdapter(ResumableUploadAdapter());
      registerAdapter(SimulatedUploadAdapter());
    }
  }

  final QueueStorage storage;
  final ConnectivityMonitor connectivityMonitor;
  final RetryPolicy retryPolicy;
  final int maxConcurrentUploads;
  final HeaderProvider? headerProvider;
  final UploadNotificationManager notifications;
  final bool _ownsConnectivity;

  final UploadQueue _queue = UploadQueue();
  final Map<String, UploadAdapter> _adapters = {};
  final Map<String, CancelToken> _tokens = {};
  final Map<String, _StopReason> _stopReasons = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, SpeedTracker> _speed = {};
  final Map<String, _Callbacks> _callbacks = {};
  final Set<String> _inFlight = {};

  final _progressController = StreamController<UploadTask>.broadcast();
  final _statusController = StreamController<UploadTask>.broadcast();
  final _summaryController = StreamController<QueueSummary>.broadcast();

  static const _uuid = Uuid();
  static const _progressSummaryInterval = Duration(milliseconds: 250);

  StreamSubscription<bool>? _connectivitySub;
  Future<void>? _initFuture;
  bool _initialized = false;
  bool _disposed = false;
  bool _online = true;
  int _pumpHolds = 0;
  DateTime _lastProgressSummary = DateTime.fromMillisecondsSinceEpoch(0);

  // ---------------------------------------------------------------------------
  // Public state
  // ---------------------------------------------------------------------------

  /// Every byte-progress update of every running task.
  Stream<UploadTask> get progressStream => _progressController.stream;

  /// Every lifecycle change (queued, running, paused, retry scheduled,
  /// completed, failed, cancelled).
  Stream<UploadTask> get statusStream => _statusController.stream;

  /// Aggregate queue state on every change (progress throttled to 4 Hz).
  Stream<QueueSummary> get summaryStream => _summaryController.stream;

  QueueSummary get summary => _queue.summarize(isConnected: _online);

  /// All tasks in display order.
  List<UploadTask> get tasks => _queue.sortedForDisplay();

  List<UploadTask> tasksWithTag(String tag) =>
      tasks.where((t) => t.tag == tag).toList();

  UploadTask? getTask(String id) => _queue.get(id);

  bool get isOnline => _online;
  bool get isInitialized => _initialized;

  /// Current state of [taskId] first, then every status/progress update.
  Stream<UploadTask> watch(String taskId) {
    late final StreamController<UploadTask> controller;
    final subs = <StreamSubscription<UploadTask>>[];
    controller = StreamController<UploadTask>(
      onListen: () {
        final current = _queue.get(taskId);
        if (current != null) controller.add(current);
        void forward(UploadTask t) {
          if (t.id == taskId && !controller.isClosed) controller.add(t);
        }

        subs
          ..add(_statusController.stream.listen(forward))
          ..add(_progressController.stream.listen(forward));
      },
      onCancel: () async {
        for (final sub in subs) {
          await sub.cancel();
        }
      },
    );
    return controller.stream;
  }

  // ---------------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------------

  void registerAdapter(UploadAdapter adapter) =>
      _adapters[adapter.id] = adapter;

  void registerAdapters(Iterable<UploadAdapter> adapters) =>
      adapters.forEach(registerAdapter);

  UploadAdapter? adapter(String id) => _adapters[id];

  /// Idempotent; safe to call concurrently.
  Future<void> init() =>
      _initFuture ??= _init().catchError((Object e, StackTrace st) {
        _initFuture = null; // allow a later call to try again
        Error.throwWithStackTrace(e, st);
      });

  Future<void> _init() async {
    await storage.init();
    await notifications.init();

    _online = await connectivityMonitor.isConnected;
    _connectivitySub = connectivityMonitor.onConnectivityChanged
        .listen(_onConnectivityChanged);

    final restored = <UploadTask>[];
    for (var task in await storage.loadAll()) {
      if (task.status == UploadStatus.running) {
        // The app died mid-upload. Adapters resume from their checkpoint.
        task =
            task.copyWith(status: UploadStatus.enqueued, speed: 0, eta: null);
        restored.add(task);
      }
      _queue.put(task);
    }
    if (restored.isNotEmpty) await _persistAll(restored);

    final now = DateTime.now();
    for (final task in _queue.withStatus(UploadStatus.enqueued)) {
      if (task.nextAttemptAt != null && task.nextAttemptAt!.isAfter(now)) {
        _armRetryTimer(task);
      }
    }

    _initialized = true;
    _emitSummary();
    _pump();
  }

  // ---------------------------------------------------------------------------
  // Enqueue
  // ---------------------------------------------------------------------------

  /// Adds an upload of one or more files ([filePaths] > 1 = one multipart
  /// request carrying all files). Returns the persisted task immediately;
  /// the transfer starts when a slot and the network are available.
  ///
  /// [simulatedFileSize] sets the size for [UploadProtocol.simulated] (or a
  /// custom adapter that doesn't read local files).
  ///
  /// Throws [ArgumentError] for an invalid request and [UploadException] if a
  /// file doesn't exist — failing fast beats a task that can never succeed.
  Future<UploadTask> enqueue({
    required List<String> filePaths,
    required String url,
    UploadProtocol protocol = UploadProtocol.standard,
    String? customAdapterId,
    String method = 'POST',
    Map<String, String> headers = const {},
    Map<String, dynamic> data = const {},
    String? fileFieldName,
    TaskPriority priority = TaskPriority.normal,
    String? tag,
    Map<String, dynamic> metadata = const {},
    int? maxRetries,
    int? simulatedFileSize,
    TaskProgressCallback? onProgress,
    TaskSuccessCallback? onSuccess,
    TaskErrorCallback? onError,
  }) async {
    _assertUsable();
    await init();

    final paths = filePaths.where((path) => path.isNotEmpty).toList();
    final needsFiles = protocol != UploadProtocol.simulated &&
        protocol != UploadProtocol.custom;
    if (url.isEmpty) throw ArgumentError.value(url, 'url', 'must not be empty');
    if (paths.isEmpty && needsFiles) {
      throw ArgumentError.value(filePaths, 'filePaths', 'must not be empty');
    }
    if (protocol == UploadProtocol.custom && customAdapterId == null) {
      throw ArgumentError(
          'customAdapterId is required for UploadProtocol.custom');
    }

    var totalBytes = 0;
    if (simulatedFileSize != null && simulatedFileSize > 0) {
      totalBytes = simulatedFileSize;
    } else {
      for (final path in paths) {
        final file = File(path);
        if (!await file.exists()) {
          throw UploadException('File not found: $path');
        }
        totalBytes += await file.length();
      }
    }

    final task = UploadTask(
      id: _uuid.v4(),
      filePaths: paths,
      url: url,
      method: method.toUpperCase(),
      headers: headers,
      data: data,
      fileFieldName: fileFieldName ?? (paths.length > 1 ? 'files' : 'file'),
      priority: priority,
      protocol: protocol,
      customAdapterId: customAdapterId,
      totalBytes: totalBytes,
      tag: tag,
      metadata: metadata,
      maxRetries: maxRetries,
    );

    if (onProgress != null || onSuccess != null || onError != null) {
      _callbacks[task.id] = _Callbacks(onProgress, onSuccess, onError);
    }
    await _commit(task);
    _pump();
    return task;
  }

  // ---------------------------------------------------------------------------
  // Controls
  // ---------------------------------------------------------------------------

  /// Pauses a queued or running task. Resumable protocols keep their
  /// checkpoint; standard uploads restart from 0 on resume.
  Future<void> pause(String taskId) async {
    await init();
    final task = _queue.get(taskId);
    if (task == null || !task.status.canPause) return;
    _cancelRetryTimer(taskId);
    await _stop(
      taskId,
      _StopReason.paused,
      task.copyWith(
        status: UploadStatus.paused,
        speed: 0,
        eta: null,
        nextAttemptAt: null,
      ),
    );
  }

  /// Resumes a paused task, or gives a failed task a fresh retry budget.
  Future<void> resume(String taskId) async {
    await init();
    final task = _queue.get(taskId);
    if (task == null || !task.status.canResume) return;
    await _commit(task.copyWith(
      status: UploadStatus.enqueued,
      error: null,
      nextAttemptAt: null,
      retryCount: task.status == UploadStatus.failed ? 0 : task.retryCount,
    ));
    _pump();
  }

  /// Re-queues any non-completed task immediately with a fresh retry budget
  /// (also skips a pending backoff). Cancelled tasks start from scratch.
  Future<void> retry(String taskId) async {
    await init();
    final task = _queue.get(taskId);
    if (task == null || task.status == UploadStatus.completed) return;
    if (task.status == UploadStatus.running) return;
    _cancelRetryTimer(taskId);
    final fromScratch = task.status == UploadStatus.cancelled;
    await _commit(task.copyWith(
      status: UploadStatus.enqueued,
      retryCount: 0,
      error: null,
      lastStatusCode: null,
      nextAttemptAt: null,
      uploadedBytes: fromScratch ? 0 : task.uploadedBytes,
      resumeState: fromScratch ? const {} : task.resumeState,
    ));
    _pump();
  }

  /// Cancels a task (kept in the list as *cancelled*). Server-side partial
  /// state is released via the adapter's `onCancelled`.
  Future<void> cancel(String taskId) async {
    await init();
    final task = _queue.get(taskId);
    if (task == null || task.status.isTerminal) return;
    _cancelRetryTimer(taskId);
    _callbacks.remove(taskId);
    await _stop(
      taskId,
      _StopReason.cancelled,
      task.copyWith(
        status: UploadStatus.cancelled,
        speed: 0,
        eta: null,
        nextAttemptAt: null,
        uploadedBytes: 0,
        resumeState: const {},
      ),
    );
    _releaseServerState(task);
  }

  /// Removes a task entirely (cancelling it first if needed).
  Future<void> deleteTask(String taskId) async {
    await init();
    final task = _queue.get(taskId);
    if (task == null) return;
    _cancelRetryTimer(taskId);
    _callbacks.remove(taskId);
    if (_inFlight.contains(taskId)) {
      _stopReasons[taskId] = _StopReason.deleted;
      _cancelToken(taskId, 'deleted');
    }
    if (!task.status.isTerminal) _releaseServerState(task);
    _queue.remove(taskId);
    await _guard(() => storage.deleteTask(taskId));
    _emitSummary();
    _pump();
  }

  Future<void> pauseAll() =>
      _batch((t) => t.status.canPause, (t) => pause(t.id));

  Future<void> resumeAll() =>
      _batch((t) => t.status.canResume, (t) => resume(t.id));

  Future<void> cancelAll() =>
      _batch((t) => !t.status.isTerminal, (t) => cancel(t.id));

  Future<void> retryAllFailed() =>
      _batch((t) => t.status == UploadStatus.failed, (t) => retry(t.id));

  /// Drops completed and cancelled tasks.
  Future<void> clearFinished() async {
    await init();
    final ids = _queue.removeTerminal();
    for (final id in ids) {
      _callbacks.remove(id);
      await _guard(() => storage.deleteTask(id));
    }
    _emitSummary();
  }

  /// Requests OS notification permission (Android 13+, iOS, macOS).
  Future<bool> requestNotificationPermission() =>
      notifications.requestPermission();

  // ---------------------------------------------------------------------------
  // Scheduling
  // ---------------------------------------------------------------------------

  void _pump() {
    if (!_initialized || _disposed || !_online || _pumpHolds > 0) return;
    var slots = maxConcurrentUploads - _inFlight.length;
    if (slots <= 0) return;
    for (final task in _queue.pendingReady(DateTime.now())) {
      if (slots <= 0) break;
      if (_inFlight.contains(task.id)) continue;
      slots--;
      _inFlight.add(task.id);
      unawaited(_run(task.id));
    }
  }

  Future<void> _run(String id) async {
    final token = CancelToken();
    _tokens[id] = token;
    try {
      var task = _queue.get(id);
      if (task == null || task.status != UploadStatus.enqueued) return;

      task = task.copyWith(
        status: UploadStatus.running,
        nextAttemptAt: null,
        speed: 0,
        eta: null,
      );
      await _commit(task);

      final adapter = _adapters[task.adapterId];
      if (adapter == null) {
        throw UploadException(
          'No adapter registered for "${task.adapterId}". '
          'Call registerAdapter() before enqueuing ${task.protocol.name} uploads.',
        );
      }

      final provider = headerProvider;
      if (provider != null) {
        Map<String, String> fresh;
        try {
          fresh = await provider(task);
        } catch (e) {
          throw UploadException(
            'HeaderProvider failed: $e',
            retryable: true,
            cause: e,
          );
        }
        final latest = _queue.get(id);
        if (latest != null && latest.status == UploadStatus.running) {
          // Memory only — sensitive values are redacted when persisted.
          _queue.put(latest.copyWith(headers: {...latest.headers, ...fresh}));
        }
      }

      // Paused / cancelled / deleted / offline while we were preparing?
      final latest = _queue.get(id);
      if (latest == null ||
          latest.status != UploadStatus.running ||
          token.isCancelled) {
        return;
      }
      task = latest;

      _speed[id] = SpeedTracker(initialBytes: task.uploadedBytes);
      final response = await adapter.upload(UploadContext(
        task: task,
        cancelToken: token,
        onProgress: (sent, total) => _onProgress(id, sent, total),
        onCheckpoint: (state, {confirmedBytes}) =>
            _onCheckpoint(id, state, confirmedBytes),
      ));
      if (!response.isSuccess) {
        throw UploadException.http(response.statusCode, response.data,
            headers: response.headers);
      }

      final stop = _stopReasons[id];
      final current = _queue.get(id);
      // Deleted or cancelled while the last bytes were in flight.
      if (current == null ||
          stop == _StopReason.deleted ||
          stop == _StopReason.cancelled) {
        return;
      }
      final done = current.copyWith(
        status: UploadStatus.completed,
        uploadedBytes: max(current.totalBytes, current.uploadedBytes),
        completedAt: DateTime.now(),
        speed: 0,
        eta: null,
        error: null,
        lastStatusCode: null,
        nextAttemptAt: null,
        resumeState: const {},
        response: response.data,
      );
      await _commit(done);
      _callbacks.remove(id)?.onSuccess?.call(done);
    } catch (error, stack) {
      if (_stopReasons.containsKey(id) || token.isCancelled) {
        // Stopped on purpose; the stopper already recorded the new state.
      } else {
        await _onAttemptFailed(id, error, stack);
      }
    } finally {
      _stopReasons.remove(id);
      _tokens.remove(id);
      _speed.remove(id);
      _inFlight.remove(id);
      _pump();
    }
  }

  void _onProgress(String id, int sent, int total) {
    final current = _queue.get(id);
    if (current == null || current.status != UploadStatus.running) return;

    final effectiveTotal = total > 0 ? total : current.totalBytes;
    final bytes = effectiveTotal > 0 ? min(sent, effectiveTotal) : sent;
    final tracker = _speed[id];
    final speed = tracker?.sample(bytes) ?? current.speed;
    final updated = current.copyWith(
      uploadedBytes: bytes,
      totalBytes: effectiveTotal,
      speed: speed,
      eta: tracker?.etaFor(effectiveTotal - bytes),
    );
    _queue.put(updated);
    if (!_progressController.isClosed) _progressController.add(updated);
    _callbacks[id]
        ?.onProgress
        ?.call(updated.progress, updated.speed, updated.eta);

    final now = DateTime.now();
    if (now.difference(_lastProgressSummary) >= _progressSummaryInterval) {
      _lastProgressSummary = now;
      _emitSummary(focus: updated);
    }
  }

  Future<void> _onCheckpoint(
    String id,
    Map<String, dynamic> state,
    int? confirmedBytes,
  ) async {
    final current = _queue.get(id);
    if (current == null || current.status == UploadStatus.cancelled) return;
    final updated = current.copyWith(
      resumeState: state,
      uploadedBytes: confirmedBytes ?? current.uploadedBytes,
    );
    _queue.put(updated);
    await _persist(updated);
  }

  Future<void> _onAttemptFailed(
      String id, Object error, StackTrace stack) async {
    final current = _queue.get(id);
    if (current == null) return;
    final statusCode = _statusCodeOf(error);
    final message = describeError(error);

    if (!_online) {
      await _commit(current.copyWith(
        status: UploadStatus.enqueued,
        speed: 0,
        eta: null,
        error: 'Waiting for network connection',
      ));
      return;
    }

    final retry = retryPolicy.shouldRetry(
      error,
      attemptsSoFar: current.retryCount,
      maxRetriesOverride: current.maxRetries,
      canRefreshAuth: headerProvider != null,
    );

    if (retry) {
      final attempt = current.retryCount + 1;
      final delay = retryPolicy.delayFor(attempt, error: error);
      final scheduled = current.copyWith(
        status: UploadStatus.enqueued,
        retryCount: attempt,
        nextAttemptAt: DateTime.now().add(delay),
        speed: 0,
        eta: null,
        error: '$message — retry $attempt in ${_humanDelay(delay)}',
        lastStatusCode: statusCode,
      );
      await _commit(scheduled);
      _armRetryTimer(scheduled);
    } else {
      final failed = current.copyWith(
        status: UploadStatus.failed,
        speed: 0,
        eta: null,
        nextAttemptAt: null,
        error: message,
        lastStatusCode: statusCode,
      );
      await _commit(failed);
      debugPrint('[floreville_upload_manager] Task $id failed: $message');
      if (kDebugMode && error is! UploadException && error is! DioException) {
        debugPrintStack(stackTrace: stack, label: 'Unexpected upload error');
      }
      _callbacks[id]?.onError?.call(failed, error);
    }
  }

  void _armRetryTimer(UploadTask task) {
    _cancelRetryTimer(task.id);
    final at = task.nextAttemptAt;
    if (at == null) return;
    final wait = at.difference(DateTime.now());
    _retryTimers[task.id] = Timer(wait.isNegative ? Duration.zero : wait, () {
      _retryTimers.remove(task.id);
      // Timers run on the monotonic clock but readiness is checked against
      // DateTime.now(), so a timer can fire a few microseconds "early". Re-arm
      // instead of pumping too soon, or the task would never be picked up.
      final current = _queue.get(task.id);
      if (current != null && current.isWaitingForRetry) {
        _armRetryTimer(current);
        return;
      }
      _pump();
    });
  }

  void _cancelRetryTimer(String id) => _retryTimers.remove(id)?.cancel();

  void _onConnectivityChanged(bool online) {
    if (_disposed || online == _online) return;
    _online = online;
    if (!online) {
      for (final id in _inFlight.toList()) {
        final task = _queue.get(id);
        if (task == null || task.status != UploadStatus.running) continue;
        _stopReasons[id] = _StopReason.offline;
        final waiting = task.copyWith(
          status: UploadStatus.enqueued,
          speed: 0,
          eta: null,
          error: 'Waiting for network connection',
        );
        _queue.put(waiting);
        _emitStatus(waiting);
        unawaited(_persist(waiting));
        _cancelToken(id, 'offline');
      }
    }
    _emitSummary();
    _pump();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Records [next] as the task's state, then stops its attempt if running.
  /// The order matters: the attempt's catch block sees the stop reason and
  /// leaves [next] alone instead of treating the cancel as a failure.
  Future<void> _stop(String id, _StopReason reason, UploadTask next) async {
    if (_inFlight.contains(id)) _stopReasons[id] = reason;
    await _commit(next);
    _cancelToken(id, reason.name);
    _pump();
  }

  void _cancelToken(String id, String reason) {
    final token = _tokens[id];
    if (token != null && !token.isCancelled) token.cancel(reason);
  }

  void _releaseServerState(UploadTask task) {
    final adapter = _adapters[task.adapterId];
    if (adapter == null) return;
    unawaited(Future<void>(() => adapter.onCancelled(task)).catchError(
      (Object e) =>
          debugPrint('[floreville_upload_manager] onCancelled failed: $e'),
    ));
  }

  Future<void> _batch(
    bool Function(UploadTask) where,
    Future<void> Function(UploadTask) action,
  ) async {
    await init();
    _pumpHolds++;
    try {
      for (final task in _queue.values.where(where).toList()) {
        await action(task);
      }
    } finally {
      _pumpHolds--;
      _pump();
    }
  }

  Future<void> _commit(UploadTask task) async {
    _queue.put(task);
    _emitStatus(task);
    _emitSummary(focus: task);
    await _persist(task);
  }

  Future<void> _persist(UploadTask task) =>
      _guard(() => storage.saveTask(task));

  Future<void> _persistAll(List<UploadTask> tasks) =>
      _guard(() => storage.saveAll(tasks));

  Future<void> _guard(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      debugPrint('[floreville_upload_manager] Storage error: $e');
    }
  }

  void _emitStatus(UploadTask task) {
    if (!_statusController.isClosed) _statusController.add(task);
  }

  void _emitSummary({UploadTask? focus}) {
    if (_disposed) return;
    final snapshot = summary;
    if (!_summaryController.isClosed) _summaryController.add(snapshot);
    final active = focus ??
        _queue.values
            .where((t) => t.status == UploadStatus.running)
            .cast<UploadTask?>()
            .firstWhere((_) => true, orElse: () => null);
    notifications.update(snapshot, focus: active);
  }

  void _assertUsable() {
    if (_disposed) throw StateError('UploadEngine has been disposed.');
  }

  static int? _statusCodeOf(Object error) {
    if (error is UploadException) return error.statusCode;
    if (error is DioException) return error.response?.statusCode;
    return null;
  }

  /// Short, user-presentable description of an upload error.
  static String describeError(Object error) {
    if (error is UploadException) {
      return error.statusCode == null
          ? error.message
          : 'HTTP ${error.statusCode}: ${error.message}';
    }
    if (error is DioException) {
      final status = error.response?.statusCode;
      return switch (error.type) {
        DioExceptionType.connectionTimeout => 'Connection timed out',
        DioExceptionType.sendTimeout => 'Upload timed out',
        DioExceptionType.receiveTimeout => 'Server response timed out',
        DioExceptionType.connectionError => 'Network unavailable',
        DioExceptionType.badCertificate => 'Untrusted server certificate',
        DioExceptionType.badResponse => 'HTTP $status',
        _ => error.message ?? error.error?.toString() ?? 'Network error',
      };
    }
    if (error is FileSystemException) {
      return 'File error: ${error.message} ${error.path ?? ''}'.trim();
    }
    return error.toString();
  }

  static String _humanDelay(Duration d) {
    if (d.inSeconds < 1) return '${d.inMilliseconds}ms';
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  /// Stops all work and releases resources. Running tasks are persisted as
  /// enqueued, so a new engine resumes them.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _connectivitySub?.cancel();
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();

    for (final id in _inFlight.toList()) {
      _stopReasons[id] = _StopReason.disposed;
      final task = _queue.get(id);
      if (task != null && task.status == UploadStatus.running) {
        await _persist(
            task.copyWith(status: UploadStatus.enqueued, speed: 0, eta: null));
      }
      _cancelToken(id, 'disposed');
    }

    for (final adapter in _adapters.values) {
      await _guard(adapter.dispose);
    }
    _callbacks.clear();
    notifications.dispose();
    if (_ownsConnectivity) connectivityMonitor.dispose();
    await _progressController.close();
    await _statusController.close();
    await _summaryController.close();
    await _guard(storage.close);
  }
}
