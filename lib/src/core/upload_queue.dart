import 'dart:math';

import '../models/queue_summary.dart';
import '../models/upload_status.dart';
import '../models/upload_task.dart';

/// In-memory task index with priority ordering. Not thread-safe by design —
/// the engine owns it and only touches it from the main isolate.
class UploadQueue {
  final Map<String, UploadTask> _tasks = {};

  int get length => _tasks.length;
  bool get isEmpty => _tasks.isEmpty;
  Iterable<UploadTask> get values => _tasks.values;

  void put(UploadTask task) => _tasks[task.id] = task;
  UploadTask? get(String id) => _tasks[id];
  UploadTask? remove(String id) => _tasks.remove(id);
  bool contains(String id) => _tasks.containsKey(id);

  List<UploadTask> withStatus(UploadStatus status) =>
      _tasks.values.where((t) => t.status == status).toList();

  /// Enqueued tasks that may start at [now] (retry backoff elapsed), highest
  /// priority first, then oldest first.
  List<UploadTask> pendingReady(DateTime now) {
    final ready = _tasks.values
        .where((t) =>
            t.status == UploadStatus.enqueued &&
            (t.nextAttemptAt == null || !t.nextAttemptAt!.isAfter(now)))
        .toList()
      ..sort(_byPriorityThenAge);
    return ready;
  }

  /// Order for list UIs: running, queued (by priority), paused, failed, then
  /// finished (newest first).
  List<UploadTask> sortedForDisplay() {
    final list = _tasks.values.toList();
    list.sort((a, b) {
      final rank = _rank(a.status).compareTo(_rank(b.status));
      if (rank != 0) return rank;
      if (a.status == UploadStatus.enqueued) return _byPriorityThenAge(a, b);
      if (a.status.isTerminal) {
        return (b.completedAt ?? b.updatedAt)
            .compareTo(a.completedAt ?? a.updatedAt);
      }
      return a.createdAt.compareTo(b.createdAt);
    });
    return list;
  }

  /// Removes completed and cancelled tasks; returns their ids.
  List<String> removeTerminal() {
    final ids = _tasks.values
        .where((t) => t.status.isTerminal)
        .map((t) => t.id)
        .toList();
    ids.forEach(_tasks.remove);
    return ids;
  }

  QueueSummary summarize({required bool isConnected}) {
    var active = 0, enqueued = 0, waiting = 0, paused = 0;
    var completed = 0, failed = 0, cancelled = 0;
    var total = 0, uploaded = 0;
    var speed = 0.0;
    final now = DateTime.now();

    for (final t in _tasks.values) {
      switch (t.status) {
        case UploadStatus.running:
          active++;
          speed += t.speed;
        case UploadStatus.enqueued:
          enqueued++;
          if (t.nextAttemptAt != null && t.nextAttemptAt!.isAfter(now)) {
            waiting++;
          }
        case UploadStatus.paused:
          paused++;
        case UploadStatus.completed:
          completed++;
        case UploadStatus.failed:
          failed++;
        case UploadStatus.cancelled:
          cancelled++;
      }
      if (t.status != UploadStatus.cancelled) {
        total += t.totalBytes;
        uploaded += t.status == UploadStatus.completed
            ? max(t.totalBytes, t.uploadedBytes)
            : t.uploadedBytes;
      }
    }

    return QueueSummary(
      totalTasks: _tasks.length,
      activeTasks: active,
      enqueuedTasks: enqueued,
      waitingForRetry: waiting,
      pausedTasks: paused,
      completedTasks: completed,
      failedTasks: failed,
      cancelledTasks: cancelled,
      totalBytes: total,
      uploadedBytes: total > 0 ? min(uploaded, total) : uploaded,
      aggregateSpeed: speed,
      isConnected: isConnected,
    );
  }

  static int _rank(UploadStatus s) => switch (s) {
        UploadStatus.running => 0,
        UploadStatus.enqueued => 1,
        UploadStatus.paused => 2,
        UploadStatus.failed => 3,
        UploadStatus.completed || UploadStatus.cancelled => 4,
      };

  static int _byPriorityThenAge(UploadTask a, UploadTask b) {
    final byPriority = b.priority.weight.compareTo(a.priority.weight);
    if (byPriority != 0) return byPriority;
    return a.createdAt.compareTo(b.createdAt);
  }
}
