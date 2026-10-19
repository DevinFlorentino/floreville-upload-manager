/// Lifecycle states of an upload task.
enum UploadStatus {
  /// Waiting in the queue (possibly for a retry delay or for the network).
  enqueued('Queued'),

  /// Actively transferring bytes.
  running('Uploading'),

  /// Paused by the user. Resumable protocols continue from their checkpoint.
  paused('Paused'),

  /// Gave up after exhausting retries or hitting a non-retryable error.
  /// Can be resumed or retried manually.
  failed('Failed'),

  /// Finished successfully.
  completed('Completed'),

  /// Cancelled by the user.
  cancelled('Cancelled');

  const UploadStatus(this.displayName);

  /// Human-readable label for UI.
  final String displayName;

  /// Completed or cancelled — the engine will never touch it again unless
  /// [retry] is called explicitly.
  bool get isTerminal =>
      this == UploadStatus.completed || this == UploadStatus.cancelled;

  /// Queued or uploading.
  bool get isActive =>
      this == UploadStatus.enqueued || this == UploadStatus.running;

  /// Whether `pause()` has an effect.
  bool get canPause =>
      this == UploadStatus.enqueued || this == UploadStatus.running;

  /// Whether `resume()` has an effect.
  bool get canResume =>
      this == UploadStatus.paused || this == UploadStatus.failed;
}
