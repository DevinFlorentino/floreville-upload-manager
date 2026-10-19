import 'package:meta/meta.dart';

import 'upload_task.dart';

/// Aggregate snapshot of the whole queue.
@immutable
class QueueSummary {
  const QueueSummary({
    this.totalTasks = 0,
    this.activeTasks = 0,
    this.enqueuedTasks = 0,
    this.waitingForRetry = 0,
    this.pausedTasks = 0,
    this.completedTasks = 0,
    this.failedTasks = 0,
    this.cancelledTasks = 0,
    this.totalBytes = 0,
    this.uploadedBytes = 0,
    this.aggregateSpeed = 0,
    this.isConnected = true,
  });

  final int totalTasks;

  /// Currently transferring.
  final int activeTasks;

  /// Waiting to start (includes [waitingForRetry]).
  final int enqueuedTasks;

  /// Enqueued tasks sitting out a retry backoff.
  final int waitingForRetry;

  final int pausedTasks;
  final int completedTasks;
  final int failedTasks;
  final int cancelledTasks;

  /// Bytes across all non-cancelled tasks.
  final int totalBytes;
  final int uploadedBytes;

  /// Sum of running tasks' speeds, bytes/second.
  final double aggregateSpeed;

  final bool isConnected;

  double get overallProgress => totalBytes <= 0
      ? 0.0
      : (uploadedBytes / totalBytes).clamp(0.0, 1.0).toDouble();

  int get overallProgressPercent => (overallProgress * 100).round();

  bool get isUploading => activeTasks > 0;
  bool get isIdle => activeTasks == 0 && enqueuedTasks == 0;
  bool get hasPaused => pausedTasks > 0;
  bool get hasFailed => failedTasks > 0;
  int get totalActiveAndPending => activeTasks + enqueuedTasks;

  String get formattedSpeed =>
      '${UploadTask.formatBytes(aggregateSpeed.round())}/s';
  String get formattedUploadedSize => UploadTask.formatBytes(uploadedBytes);
  String get formattedTotalSize => UploadTask.formatBytes(totalBytes);

  /// Changes whenever a task changes state (but not on byte progress).
  String get stateKey =>
      '$activeTasks|$enqueuedTasks|$pausedTasks|$completedTasks|$failedTasks|$cancelledTasks|$isConnected';

  @override
  String toString() =>
      'QueueSummary(active: $activeTasks, queued: $enqueuedTasks, paused: $pausedTasks, '
      'done: $completedTasks, failed: $failedTasks, $overallProgressPercent%)';
}
