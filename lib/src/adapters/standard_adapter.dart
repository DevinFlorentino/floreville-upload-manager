import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/upload_exception.dart';
import '../models/upload_task.dart';
import '../utils/http_utils.dart';
import 'upload_adapter.dart';

/// One-request upload — multipart/form-data or a raw binary body.
///
/// Body mode (override with `metadata: {'bodyMode': 'raw' | 'multipart'}`):
/// * **raw** by default for single-file `PUT` (presigned S3/GCS/R2 URLs,
///   Supabase signed upload URLs). Sends the file bytes as the body with
///   `Content-Type` from `metadata['contentType']` or the file extension.
/// * **multipart** otherwise. Every path is added under `fileFieldName`;
///   `data` entries become form fields (lists repeat the field, maps are
///   JSON-encoded).
///
/// Not resumable: an interrupted attempt restarts from 0. Use the resumable
/// or S3 protocol for large files on flaky networks.
class StandardUploadAdapter extends UploadAdapter {
  StandardUploadAdapter({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  static const String adapterId = 'standard';

  final Dio _dio;

  @override
  String get id => adapterId;

  @override
  Future<UploadResponse> upload(UploadContext context) async {
    final task = context.task;
    if (task.filePaths.isEmpty) {
      throw const UploadException('Task has no files to upload.');
    }

    var size = 0;
    for (final path in task.filePaths) {
      final file = File(path);
      if (!await file.exists()) {
        throw UploadException('File not found: $path');
      }
      size += await file.length();
    }

    final Object body;
    Map<String, dynamic> headers = Map<String, dynamic>.of(task.headers);

    if (_useRawBody(task)) {
      if (task.isMultiFile) {
        throw const UploadException(
          'bodyMode "raw" supports a single file. Use multipart for bundles.',
        );
      }
      final path = task.primaryPath;
      final contentType = hasHeader(headers, Headers.contentTypeHeader)
          ? null
          : (task.metadata['contentType'] as String?) ?? mimeTypeFor(path);
      headers = mergeHeaders(task.headers, {
        if (contentType != null) Headers.contentTypeHeader: contentType,
        Headers.contentLengthHeader: '$size',
      });
      body = File(path).openRead();
    } else {
      // Dio must set the multipart boundary itself.
      headers = withoutHeader(headers, Headers.contentTypeHeader);
      final form = FormData();
      for (final path in task.filePaths) {
        final mime = (!task.isMultiFile
                ? task.metadata['contentType'] as String?
                : null) ??
            mimeTypeFor(path);
        form.files.add(MapEntry(
          task.fileFieldName,
          await MultipartFile.fromFile(
            path,
            filename: p.basename(path),
            contentType: DioMediaType.parse(mime),
          ),
        ));
      }
      task.data.forEach((key, value) {
        if (value == null) return;
        if (value is Iterable) {
          for (final item in value) {
            form.fields.add(MapEntry(key, _fieldValue(item)));
          }
        } else {
          form.fields.add(MapEntry(key, _fieldValue(value)));
        }
      });
      body = form;
    }

    final response = await _dio.request<dynamic>(
      task.url,
      data: body,
      cancelToken: context.cancelToken,
      options: Options(
        method: task.method,
        headers: headers,
        responseType: ResponseType.json,
        validateStatus: (_) => true,
      ),
      onSendProgress: (sent, total) =>
          context.reportProgress(sent, total > 0 ? total : size),
    );

    final status = response.statusCode ?? 0;
    final result = UploadResponse(
      statusCode: status,
      data: response.data,
      headers: response.headers.map,
    );
    if (!result.isSuccess) {
      throw UploadException.http(
        status,
        response.data,
        headers: response.headers.map,
      );
    }
    return result;
  }

  static bool _useRawBody(UploadTask task) {
    final mode = task.metadata['bodyMode'];
    if (mode == 'raw') return true;
    if (mode == 'multipart') return false;
    return task.method.toUpperCase() == 'PUT' && !task.isMultiFile;
  }

  static String _fieldValue(Object? value) {
    if (value is String) return value;
    if (value is Map) return jsonEncode(value);
    return '$value';
  }
}
