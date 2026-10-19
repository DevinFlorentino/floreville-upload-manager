import 'dart:math';

import 'package:dio/dio.dart';

import 'upload_adapter.dart';

/// Network-free fake transfer for demos, screenshots and UI work.
///
/// Size comes from `simulatedFileSize` (else [defaultSize]); speed from
/// `metadata['simulatedSpeed']` (bytes/s, else [bytesPerSecond]). Progress is
/// checkpointed roughly every second, so pause/resume and app restarts
/// behave like a real resumable upload.
class SimulatedUploadAdapter extends UploadAdapter {
  SimulatedUploadAdapter({
    this.bytesPerSecond = 2 * 1024 * 1024,
    this.tick = const Duration(milliseconds: 100),
    this.failureProbability = 0,
    this.defaultSize = 10 * 1024 * 1024,
    Random? random,
  })  : assert(failureProbability >= 0 && failureProbability <= 1),
        _random = random ?? Random();

  static const String adapterId = 'simulated';

  final int bytesPerSecond;
  final Duration tick;

  /// Chance per tick of a simulated connection drop (retryable).
  final double failureProbability;
  final int defaultSize;
  final Random _random;

  @override
  String get id => adapterId;

  @override
  Future<UploadResponse> upload(UploadContext context) async {
    final task = context.task;
    final size = task.totalBytes > 0 ? task.totalBytes : defaultSize;
    final saved = (context.resumeState['offset'] as num?)?.toInt() ?? 0;
    var offset = min(max(saved, 0), size);
    final speed =
        (task.metadata['simulatedSpeed'] as num?)?.toInt() ?? bytesPerSecond;
    final perTick = max(1, (speed * tick.inMicroseconds / 1e6).round());
    var lastCheckpoint = DateTime.now();

    context.reportProgress(offset, size);
    while (offset < size) {
      context.throwIfCancelled();
      if (failureProbability > 0 && _random.nextDouble() < failureProbability) {
        throw DioException(
          requestOptions: RequestOptions(path: task.url),
          type: DioExceptionType.connectionError,
          message: 'Simulated network drop',
        );
      }
      await Future<void>.delayed(tick);
      context.throwIfCancelled();

      offset = min(offset + perTick, size);
      context.reportProgress(offset, size);
      final now = DateTime.now();
      if (offset == size ||
          now.difference(lastCheckpoint) >= const Duration(seconds: 1)) {
        lastCheckpoint = now;
        await context.checkpoint({'offset': offset}, confirmedBytes: offset);
      }
    }

    return UploadResponse(
      statusCode: 200,
      data: {'ok': true, 'simulated': true, 'bytes': size},
    );
  }
}
