import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../models/upload_exception.dart';
import '../models/upload_task.dart';
import '../utils/http_utils.dart';
import 'upload_adapter.dart';

/// Asks the server how many bytes it already holds. Return null when
/// unknown (the local checkpoint is then trusted).
typedef ResumableOffsetProbe = Future<int?> Function(
  Dio dio,
  UploadTask task,
  String url,
  int fileSize,
);

/// Chunked upload using `Content-Range: bytes START-END/TOTAL`.
///
/// Each chunk is sent with `task.method` to the task URL. A chunk counts as
/// accepted on 2xx, or on `308 Resume Incomplete` for non-final chunks
/// (Google-style). If the server answers with a `Range: bytes=0-N` header,
/// N+1 is taken as the confirmed offset, so partially accepted chunks are
/// re-sent correctly.
///
/// After every accepted chunk the offset is checkpointed to disk, so pause,
/// network loss, crash or app kill all resume from the last chunk instead of
/// 0%. If the file's size or modification time changed, the checkpoint is
/// discarded and the upload restarts.
class ResumableUploadAdapter extends UploadAdapter {
  ResumableUploadAdapter({
    Dio? dio,
    this.chunkSize = 2 * 1024 * 1024,
    this.offsetProbe,
    this.followLocationHeader = false,
  })  : assert(chunkSize > 0),
        _dio = dio ??
            Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  static const String adapterId = 'resumable';

  final Dio _dio;

  /// Bytes per request. Larger = fewer round-trips, more to resend on a drop.
  final int chunkSize;

  /// Optional server offset query before resuming, e.g. [contentRangeProbe].
  final ResumableOffsetProbe? offsetProbe;

  /// Send subsequent chunks to the `Location` returned by a non-final chunk
  /// (servers that create an upload session on the first chunk).
  final bool followLocationHeader;

  @override
  String get id => adapterId;

  @override
  Future<UploadResponse> upload(UploadContext context) async {
    final task = context.task;
    if (task.filePaths.length != 1) {
      throw const UploadException(
        'The resumable protocol uploads exactly one file per task.',
      );
    }
    final file = File(task.primaryPath);
    if (!await file.exists()) {
      throw UploadException('File not found: ${task.primaryPath}');
    }

    final fingerprint = await FileFingerprint.of(file);
    final size = fingerprint.size;
    final state = context.resumeState;

    var url = task.url;
    var offset = 0;
    if (fingerprint.matches(state)) {
      offset = (state['offset'] as num?)?.toInt() ?? 0;
      url = (state['url'] as String?) ?? task.url;
    }
    if (offset < 0 || offset > size) offset = 0;

    if (offsetProbe != null && offset > 0) {
      final remote = await offsetProbe!(_dio, task, url, size);
      if (remote != null && remote >= 0 && remote <= size) offset = remote;
    }

    if (size == 0) return _sendEmpty(context, url);

    context.reportProgress(offset, size);
    UploadResponse? last;
    final raf = await file.open();
    try {
      while (offset < size) {
        context.throwIfCancelled();

        final start = offset;
        final length = min(chunkSize, size - start);
        final end = start + length - 1;
        final isFinal = end == size - 1;

        await raf.setPosition(start);
        final bytes = await raf.read(length);
        if (bytes.length != length) {
          throw const UploadException(
            'File changed while uploading (short read).',
            retryable: true,
          );
        }

        final response = await _dio.request<dynamic>(
          url,
          data: Stream<List<int>>.value(bytes),
          cancelToken: context.cancelToken,
          options: Options(
            method: task.method,
            headers: mergeHeaders(task.headers, {
              Headers.contentTypeHeader: 'application/octet-stream',
              Headers.contentLengthHeader: '$length',
              'Content-Range': 'bytes $start-$end/$size',
            }),
            responseType: ResponseType.json,
            validateStatus: (_) => true,
          ),
          onSendProgress: (sent, _) =>
              context.reportProgress(start + sent, size),
        );

        final status = response.statusCode ?? 0;
        final accepted =
            (status >= 200 && status < 300) || (!isFinal && status == 308);
        if (!accepted) {
          throw UploadException.http(
            status,
            response.data,
            headers: response.headers.map,
          );
        }

        offset = (status >= 200 && status < 300 && isFinal)
            ? size
            : _confirmedOffset(response.headers, fallback: end + 1, size: size);
        if (offset <= start) {
          // Server acknowledged the request but kept none of the bytes —
          // bail out instead of looping on the same chunk forever.
          throw UploadException(
            'Server did not accept bytes $start-$end.',
            retryable: true,
          );
        }

        if (followLocationHeader && !isFinal) {
          final location = response.headers.value('location');
          if (location != null && location.isNotEmpty) {
            url = Uri.parse(url).resolve(location).toString();
          }
        }

        last = UploadResponse(
          statusCode: status,
          data: response.data,
          headers: response.headers.map,
        );
        context.reportProgress(offset, size);
        await context.checkpoint(
          {...fingerprint.toJson(), 'offset': offset, 'url': url},
          confirmedBytes: offset,
        );
      }
    } finally {
      await raf.close();
    }

    // offset == size on entry means the final chunk was confirmed in an
    // earlier attempt that died before completion was recorded.
    return last ?? const UploadResponse(statusCode: 200);
  }

  Future<UploadResponse> _sendEmpty(UploadContext context, String url) async {
    final task = context.task;
    final response = await _dio.request<dynamic>(
      url,
      data: Stream<List<int>>.value(const <int>[]),
      cancelToken: context.cancelToken,
      options: Options(
        method: task.method,
        headers: mergeHeaders(task.headers, {
          Headers.contentTypeHeader: 'application/octet-stream',
          Headers.contentLengthHeader: '0',
        }),
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw UploadException.http(status, response.data,
          headers: response.headers.map);
    }
    return UploadResponse(
        statusCode: status, data: response.data, headers: response.headers.map);
  }

  static int _confirmedOffset(
    Headers headers, {
    required int fallback,
    required int size,
  }) {
    final range = headers.value('range');
    if (range != null) {
      final end = _rangeEnd(range);
      if (end != null) return min(end + 1, size);
    }
    final uploadOffset = int.tryParse(headers.value('upload-offset') ?? '');
    if (uploadOffset != null) return min(uploadOffset, size);
    return fallback;
  }

  static int? _rangeEnd(String header) {
    final match = RegExp(r'bytes=\d+-(\d+)').firstMatch(header);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Probe for servers implementing the GCS-style status query: an empty
  /// `PUT` with `Content-Range: bytes */TOTAL`, answered with `308` +
  /// `Range: bytes=0-N` (or 2xx if already complete).
  static Future<int?> contentRangeProbe(
    Dio dio,
    UploadTask task,
    String url,
    int fileSize,
  ) async {
    try {
      final response = await dio.request<dynamic>(
        url,
        data: Stream<List<int>>.value(const <int>[]),
        options: Options(
          method: 'PUT',
          headers: mergeHeaders(task.headers, {
            'Content-Range': 'bytes */$fileSize',
            Headers.contentLengthHeader: '0',
          }),
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 200 && status < 300) return fileSize;
      if (status == 308) {
        final range = response.headers.value('range');
        if (range == null) return 0;
        final end = _rangeEnd(range);
        return end == null ? null : end + 1;
      }
    } catch (_) {
      // Fall back to the local checkpoint.
    }
    return null;
  }
}
