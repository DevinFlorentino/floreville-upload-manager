import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/upload_exception.dart';
import '../models/upload_task.dart';
import '../utils/http_utils.dart';
import 'upload_adapter.dart';

/// An open S3 multipart upload.
@immutable
class S3MultipartSession {
  const S3MultipartSession({required this.uploadId, required this.key});

  final String uploadId;

  /// Object key in the bucket.
  final String key;
}

/// A presigned URL for one part.
@immutable
class S3PartTarget {
  const S3PartTarget({required this.url, this.headers = const {}});

  final String url;

  /// Extra headers the signature requires (if any).
  final Map<String, String> headers;
}

@immutable
class S3CompletedPart {
  const S3CompletedPart({required this.partNumber, required this.eTag});

  factory S3CompletedPart.fromJson(Map<String, dynamic> json) =>
      S3CompletedPart(
        partNumber: (json['partNumber'] as num).toInt(),
        eTag: json['eTag'] as String,
      );

  final int partNumber;

  /// Exactly as S3 returned it (including quotes).
  final String eTag;

  Map<String, dynamic> toJson() => {'partNumber': partNumber, 'eTag': eTag};
}

/// Your backend's half of the S3 multipart flow. Credentials stay on the
/// server; the app only ever sees short-lived presigned part URLs.
///
/// Use [HttpS3MultipartSigner] for the ready-made JSON contract (see
/// `doc/s3_signer_backend.md` for a Supabase Edge Function implementation),
/// or implement this yourself.
abstract class S3MultipartSigner {
  /// CreateMultipartUpload.
  Future<S3MultipartSession> initiate(
    UploadTask task, {
    required String fileName,
    required String contentType,
    required int fileSize,
  });

  /// Presign UploadPart for [partNumber].
  Future<S3PartTarget> signPart(
    UploadTask task,
    S3MultipartSession session, {
    required int partNumber,
    required int contentLength,
  });

  /// CompleteMultipartUpload. The returned response becomes `task.response`.
  Future<UploadResponse> complete(
    UploadTask task,
    S3MultipartSession session,
    List<S3CompletedPart> parts,
  );

  /// AbortMultipartUpload (best effort).
  Future<void> abort(UploadTask task, S3MultipartSession session);
}

/// Multipart upload to S3 or any S3-compatible store (Cloudflare R2, MinIO,
/// Wasabi, DigitalOcean Spaces, Backblaze B2 S3 API) via presigned part URLs.
///
/// Parts are uploaded sequentially. Each confirmed part's ETag is
/// checkpointed, so a pause, network drop or app restart continues with the
/// next part. Parts are presigned just before upload, so URL expiry between
/// attempts is a non-issue (a 403 on a part is retried with a fresh URL).
///
/// `task.headers` (e.g. your Authorization from a `HeaderProvider`) go to
/// your signer backend, never to S3 — they would break the signature.
class S3MultipartUploadAdapter extends UploadAdapter {
  S3MultipartUploadAdapter({
    required this.signer,
    Dio? dio,
    this.partSize = 8 * 1024 * 1024,
  }) : _dio = dio ??
            Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  static const String adapterId = 's3_multipart';

  /// S3 minimum for every part except the last.
  static const int minPartSize = 5 * 1024 * 1024;

  /// S3 maximum number of parts.
  static const int maxParts = 10000;

  final S3MultipartSigner signer;
  final Dio _dio;

  /// Requested part size; raised automatically to respect [minPartSize] and
  /// [maxParts].
  final int partSize;

  @override
  String get id => adapterId;

  int effectivePartSize(int fileSize) =>
      max(max(partSize, minPartSize), (fileSize / maxParts).ceil());

  @override
  Future<UploadResponse> upload(UploadContext context) async {
    final task = context.task;
    if (task.filePaths.length != 1) {
      throw const UploadException(
        'S3 multipart uploads exactly one file per task.',
      );
    }
    final file = File(task.primaryPath);
    if (!await file.exists()) {
      throw UploadException('File not found: ${task.primaryPath}');
    }

    final fingerprint = await FileFingerprint.of(file);
    final size = fingerprint.size;
    final state = context.resumeState;
    final parts = <int, S3CompletedPart>{};

    S3MultipartSession? restored;
    var chunk = effectivePartSize(size);
    final savedSession = _sessionFrom(state);
    if (savedSession != null && fingerprint.matches(state)) {
      restored = savedSession;
      chunk = (state['partSize'] as num?)?.toInt() ?? chunk;
      for (final raw in (state['parts'] as List<dynamic>? ?? const [])) {
        if (raw is Map) {
          final part = S3CompletedPart.fromJson(
            raw.map((k, v) => MapEntry(k.toString(), v)),
          );
          parts[part.partNumber] = part;
        }
      }
    } else if (savedSession != null) {
      // The file changed since the session was opened — release it.
      unawaited(_abortQuietly(task, savedSession));
    }

    final contentType =
        (task.metadata['contentType'] as String?) ?? mimeTypeFor(file.path);
    final session = restored ??
        await signer.initiate(
          task,
          fileName: p.basename(file.path),
          contentType: contentType,
          fileSize: size,
        );
    if (restored == null) {
      await context.checkpoint(
        _state(fingerprint, session, chunk, parts.values),
        confirmedBytes: 0,
      );
    }

    final totalParts = size == 0 ? 1 : (size / chunk).ceil();
    parts.removeWhere((n, _) => n > totalParts);
    var confirmed =
        parts.keys.fold<int>(0, (sum, n) => sum + _partLength(n, chunk, size));
    context.reportProgress(confirmed, size);

    final raf = await file.open();
    try {
      for (var n = 1; n <= totalParts; n++) {
        if (parts.containsKey(n)) continue;
        context.throwIfCancelled();

        final start = (n - 1) * chunk;
        final length = _partLength(n, chunk, size);
        await raf.setPosition(start);
        final bytes = await raf.read(length);
        if (bytes.length != length) {
          throw const UploadException(
            'File changed while uploading (short read).',
          );
        }

        final target = await signer.signPart(
          task,
          session,
          partNumber: n,
          contentLength: length,
        );
        context.throwIfCancelled();

        final base = confirmed;
        final response = await _dio.put<dynamic>(
          target.url,
          data: Stream<List<int>>.value(bytes),
          cancelToken: context.cancelToken,
          options: Options(
            headers: mergeHeaders(target.headers, {
              Headers.contentLengthHeader: '$length',
            }),
            responseType: ResponseType.plain,
            validateStatus: (_) => true,
          ),
          onSendProgress: (sent, _) =>
              context.reportProgress(base + sent, size),
        );

        final status = response.statusCode ?? 0;
        if (status < 200 || status >= 300) {
          throw UploadException.http(
            status,
            response.data,
            headers: response.headers.map,
            // 403 here is almost always an expired/invalid presigned URL;
            // the next attempt presigns again.
            retryableOverride: status == 403 ? true : null,
          );
        }

        final eTag = response.headers.value('etag');
        if (eTag == null || eTag.isEmpty) {
          throw const UploadException(
            'Storage did not return an ETag for the uploaded part. '
            'S3-compatible gateways must expose the ETag header.',
          );
        }

        parts[n] = S3CompletedPart(partNumber: n, eTag: eTag);
        confirmed += length;
        context.reportProgress(confirmed, size);
        await context.checkpoint(
          _state(fingerprint, session, chunk, parts.values),
          confirmedBytes: confirmed,
        );
      }
    } finally {
      await raf.close();
    }

    context.throwIfCancelled();
    final ordered = parts.values.toList()
      ..sort((a, b) => a.partNumber.compareTo(b.partNumber));
    return signer.complete(task, session, ordered);
  }

  @override
  Future<void> onCancelled(UploadTask task) async {
    final session = _sessionFrom(task.resumeState);
    if (session != null) await _abortQuietly(task, session);
  }

  Future<void> _abortQuietly(
      UploadTask task, S3MultipartSession session) async {
    try {
      await signer.abort(task, session);
    } catch (e) {
      debugPrint(
          '[floreville_upload_manager] S3 abort failed for ${session.key}: $e');
    }
  }

  static S3MultipartSession? _sessionFrom(Map<String, dynamic> state) {
    final uploadId = state['uploadId'];
    final key = state['key'];
    if (uploadId is String && key is String) {
      return S3MultipartSession(uploadId: uploadId, key: key);
    }
    return null;
  }

  static int _partLength(int partNumber, int chunk, int size) {
    if (size == 0) return 0;
    final start = (partNumber - 1) * chunk;
    return max(0, min(chunk, size - start));
  }

  static Map<String, dynamic> _state(
    FileFingerprint fingerprint,
    S3MultipartSession session,
    int chunk,
    Iterable<S3CompletedPart> parts,
  ) =>
      {
        ...fingerprint.toJson(),
        'uploadId': session.uploadId,
        'key': session.key,
        'partSize': chunk,
        'parts': parts.map((part) => part.toJson()).toList(),
      };
}

/// [S3MultipartSigner] talking to four JSON endpoints under [baseUrl]:
///
/// | Endpoint          | Request body                                        | Response              |
/// |-------------------|-----------------------------------------------------|-----------------------|
/// | `POST /initiate`  | `fileName, contentType, fileSize, tag, metadata`    | `{uploadId, key}`     |
/// | `POST /sign-part` | `uploadId, key, partNumber, contentLength`          | `{url, headers?}`     |
/// | `POST /complete`  | `uploadId, key, parts: [{partNumber, eTag}]`        | anything (→ response) |
/// | `POST /abort`     | `uploadId, key`                                     | anything              |
///
/// `task.headers` are forwarded to every call — put your auth there (ideally
/// via a `HeaderProvider`). The backend must check that the caller owns
/// `key` on sign-part/complete/abort.
class HttpS3MultipartSigner implements S3MultipartSigner {
  HttpS3MultipartSigner({required String baseUrl, Dio? dio})
      : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _dio = dio ??
            Dio(BaseOptions(connectTimeout: const Duration(seconds: 20)));

  final String baseUrl;
  final Dio _dio;

  @override
  Future<S3MultipartSession> initiate(
    UploadTask task, {
    required String fileName,
    required String contentType,
    required int fileSize,
  }) async {
    final json = await _post(task, 'initiate', {
      'fileName': fileName,
      'contentType': contentType,
      'fileSize': fileSize,
      'tag': task.tag,
      'metadata': task.metadata,
    });
    final uploadId = json['uploadId'];
    final key = json['key'];
    if (uploadId is! String || key is! String) {
      throw const UploadException(
        'Signer /initiate must return {"uploadId": string, "key": string}.',
      );
    }
    return S3MultipartSession(uploadId: uploadId, key: key);
  }

  @override
  Future<S3PartTarget> signPart(
    UploadTask task,
    S3MultipartSession session, {
    required int partNumber,
    required int contentLength,
  }) async {
    final json = await _post(task, 'sign-part', {
      'uploadId': session.uploadId,
      'key': session.key,
      'partNumber': partNumber,
      'contentLength': contentLength,
    });
    final url = json['url'];
    if (url is! String) {
      throw const UploadException(
          'Signer /sign-part must return {"url": string}.');
    }
    final headers = json['headers'];
    return S3PartTarget(
      url: url,
      headers: headers is Map
          ? headers.map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
    );
  }

  @override
  Future<UploadResponse> complete(
    UploadTask task,
    S3MultipartSession session,
    List<S3CompletedPart> parts,
  ) async {
    final json = await _post(task, 'complete', {
      'uploadId': session.uploadId,
      'key': session.key,
      'parts': parts.map((part) => part.toJson()).toList(),
    });
    return UploadResponse(statusCode: 200, data: json);
  }

  @override
  Future<void> abort(UploadTask task, S3MultipartSession session) async {
    await _post(task, 'abort', {
      'uploadId': session.uploadId,
      'key': session.key,
    });
  }

  Future<Map<String, dynamic>> _post(
    UploadTask task,
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _dio.post<dynamic>(
      '$baseUrl/$path',
      data: jsonEncode(body),
      options: Options(
        headers: mergeHeaders(task.headers, {
          Headers.contentTypeHeader: Headers.jsonContentType,
        }),
        responseType: ResponseType.json,
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw UploadException.http(status, response.data,
          headers: response.headers.map);
    }
    final data = response.data;
    if (data is Map) return data.map((k, v) => MapEntry(k.toString(), v));
    if (data is String && data.trim().isNotEmpty) {
      final decoded = jsonDecode(data);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    }
    return <String, dynamic>{};
  }
}
