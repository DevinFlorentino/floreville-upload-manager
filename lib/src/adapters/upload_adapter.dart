import 'package:dio/dio.dart';

import '../models/upload_task.dart';

typedef UploadProgressCallback = void Function(int sentBytes, int totalBytes);

/// Persists adapter resume state. [confirmedBytes] = bytes the server has
/// definitely accepted (drives progress after a restart).
typedef CheckpointCallback = Future<void> Function(
  Map<String, dynamic> state, {
  int? confirmedBytes,
});

/// Result of a finished upload.
class UploadResponse {
  const UploadResponse({
    required this.statusCode,
    this.data,
    this.headers = const {},
  });

  final int statusCode;
  final Object? data;
  final Map<String, List<String>> headers;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  @override
  String toString() => 'UploadResponse($statusCode)';
}

/// Everything an adapter needs for one attempt.
class UploadContext {
  UploadContext({
    required this.task,
    required this.cancelToken,
    required UploadProgressCallback onProgress,
    required CheckpointCallback onCheckpoint,
  })  : _onProgress = onProgress,
        _onCheckpoint = onCheckpoint;

  /// Snapshot of the task at the start of the attempt, with fresh headers
  /// from the `HeaderProvider` already merged in.
  final UploadTask task;

  /// Cancelled when the user pauses/cancels or the device goes offline.
  /// Pass it to every Dio call.
  final CancelToken cancelToken;

  final UploadProgressCallback _onProgress;
  final CheckpointCallback _onCheckpoint;

  /// The last persisted checkpoint ({} on a fresh start).
  Map<String, dynamic> get resumeState => task.resumeState;

  bool get isCancelled => cancelToken.isCancelled;

  void reportProgress(int sentBytes, int totalBytes) =>
      _onProgress(sentBytes, totalBytes);

  /// Persist resume state. Call after every chunk the server confirmed.
  Future<void> checkpoint(Map<String, dynamic> state, {int? confirmedBytes}) =>
      _onCheckpoint(state, confirmedBytes: confirmedBytes);

  /// Throws a Dio cancel error if the attempt was stopped. Call between
  /// chunks so long loops stop promptly.
  void throwIfCancelled() {
    if (cancelToken.isCancelled) {
      throw DioException(
        requestOptions: RequestOptions(path: task.url),
        type: DioExceptionType.cancel,
        error: cancelToken.cancelError?.error ?? 'cancelled',
      );
    }
  }
}

/// A transport. Implement this to support another backend (GraphQL upload,
/// Firebase Storage, a proprietary API, …) and register it with
/// `UploadEngine.registerAdapter`; then enqueue with
/// `protocol: UploadProtocol.custom, customAdapterId: yourAdapter.id`.
///
/// Contract:
/// * Honour `context.cancelToken` (pass it to Dio; call `throwIfCancelled`
///   between chunks).
/// * Report progress with `context.reportProgress`.
/// * For resumable transports, call `context.checkpoint` after each confirmed
///   chunk and read `context.resumeState` at the start.
/// * Throw on failure. Throw `UploadException` with `retryable` /
///   `statusCode` set so the retry policy can decide correctly.
abstract class UploadAdapter {
  /// Registry key.
  String get id;

  Future<UploadResponse> upload(UploadContext context);

  /// Called (best effort, not awaited by the queue) when a task is
  /// cancelled or deleted, so server-side state can be released — e.g.
  /// aborting an S3 multipart upload.
  Future<void> onCancelled(UploadTask task) async {}

  Future<void> dispose() async {}
}
