import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'task_priority.dart';
import 'upload_protocol.dart';
import 'upload_status.dart';

/// Sentinel that lets [UploadTask.copyWith] distinguish "not passed" from an
/// explicit `null` (so errors, ETAs and retry times can actually be cleared).
const Object _unset = Object();

/// One unit of work in the queue: one HTTP upload of one or more files.
///
/// Immutable — every state change produces a new instance via [copyWith].
@immutable
class UploadTask {
  UploadTask({
    required this.id,
    required List<String> filePaths,
    required this.url,
    this.method = 'POST',
    Map<String, String> headers = const {},
    Map<String, dynamic> data = const {},
    this.fileFieldName = 'file',
    this.priority = TaskPriority.normal,
    this.status = UploadStatus.enqueued,
    this.protocol = UploadProtocol.standard,
    this.customAdapterId,
    this.totalBytes = 0,
    this.uploadedBytes = 0,
    this.speed = 0,
    this.eta,
    this.retryCount = 0,
    this.maxRetries,
    this.error,
    this.lastStatusCode,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.completedAt,
    this.nextAttemptAt,
    this.tag,
    Map<String, dynamic> metadata = const {},
    Map<String, dynamic> resumeState = const {},
    this.response,
  })  : filePaths = List<String>.unmodifiable(filePaths),
        headers = Map<String, String>.unmodifiable(headers),
        data = Map<String, dynamic>.unmodifiable(data),
        metadata = Map<String, dynamic>.unmodifiable(metadata),
        resumeState = Map<String, dynamic>.unmodifiable(resumeState),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Unique id (UUID v4).
  final String id;

  /// Local files sent by this task. More than one = a multi-file bundle sent
  /// in a single multipart request.
  final List<String> filePaths;

  /// Target endpoint.
  final String url;

  /// HTTP method. Defaults to POST.
  final String method;

  /// Request headers. Sensitive keys (Authorization, Cookie, apikey, …) are
  /// stripped when persisted to disk — supply them through a `HeaderProvider`
  /// so they are fresh on every attempt, including after an app restart.
  final Map<String, String> headers;

  /// Extra multipart form fields.
  final Map<String, dynamic> data;

  /// Multipart field name for the file(s).
  final String fileFieldName;

  final TaskPriority priority;
  final UploadStatus status;
  final UploadProtocol protocol;

  /// Adapter id when [protocol] is [UploadProtocol.custom].
  final String? customAdapterId;

  /// Total payload size in bytes (0 if unknown).
  final int totalBytes;

  /// Bytes sent so far (for resumable protocols: confirmed by the server).
  final int uploadedBytes;

  /// Smoothed transfer speed in bytes/second.
  final double speed;

  /// Estimated time remaining.
  final Duration? eta;

  /// Automatic retries already consumed.
  final int retryCount;

  /// Per-task override of the retry policy's `maxRetries`.
  final int? maxRetries;

  /// Last error description (null when healthy).
  final String? error;

  /// HTTP status of the last failed attempt, if any.
  final int? lastStatusCode;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  /// When an enqueued task becomes eligible again after a failure. The queue
  /// will not start the task before this time.
  final DateTime? nextAttemptAt;

  /// Optional grouping tag ("avatars", "documents", …).
  final String? tag;

  /// Free-form app metadata, persisted with the task. Reserved keys read by
  /// built-in adapters: `contentType`, `bodyMode` ('raw' | 'multipart'),
  /// `simulatedSpeed`.
  final Map<String, dynamic> metadata;

  /// Adapter-owned resume checkpoint (offsets, session ids, part ETags).
  /// Persisted after every confirmed chunk; cleared on completion/cancel.
  final Map<String, dynamic> resumeState;

  /// Server response body of the successful attempt.
  final Object? response;

  // ---------------------------------------------------------------------------
  // Derived values
  // ---------------------------------------------------------------------------

  String get primaryPath => filePaths.isEmpty ? '' : filePaths.first;

  bool get isMultiFile => filePaths.length > 1;

  /// Registry key of the adapter that will run this task.
  String get adapterId => protocol == UploadProtocol.custom
      ? (customAdapterId ?? UploadProtocol.custom.adapterId)
      : protocol.adapterId;

  /// 0.0 – 1.0.
  double get progress {
    if (totalBytes <= 0) return status == UploadStatus.completed ? 1.0 : 0.0;
    return (uploadedBytes / totalBytes).clamp(0.0, 1.0).toDouble();
  }

  int get progressPercent => (progress * 100).round();

  /// True while the task waits out a retry backoff.
  bool get isWaitingForRetry =>
      status == UploadStatus.enqueued &&
      nextAttemptAt != null &&
      nextAttemptAt!.isAfter(DateTime.now());

  String get fileName {
    if (isMultiFile) return '${filePaths.length} files';
    if (filePaths.isEmpty) return metadata['displayName']?.toString() ?? id;
    return p.basename(primaryPath);
  }

  String get formattedTotalSize => formatBytes(totalBytes);
  String get formattedUploadedSize => formatBytes(uploadedBytes);
  String get formattedSpeed => '${formatBytes(speed.round())}/s';

  String get formattedEta {
    final value = eta;
    if (value == null) return '--';
    final seconds = value.inSeconds;
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
    return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
  }

  // ---------------------------------------------------------------------------
  // Copy
  // ---------------------------------------------------------------------------

  /// Returns a copy with the given fields replaced. Nullable fields marked
  /// `Object?` accept an explicit `null` to clear them.
  UploadTask copyWith({
    List<String>? filePaths,
    String? url,
    String? method,
    Map<String, String>? headers,
    Map<String, dynamic>? data,
    String? fileFieldName,
    TaskPriority? priority,
    UploadStatus? status,
    UploadProtocol? protocol,
    String? customAdapterId,
    int? totalBytes,
    int? uploadedBytes,
    double? speed,
    Object? eta = _unset,
    int? retryCount,
    int? maxRetries,
    Object? error = _unset,
    Object? lastStatusCode = _unset,
    Object? completedAt = _unset,
    Object? nextAttemptAt = _unset,
    String? tag,
    Map<String, dynamic>? metadata,
    Map<String, dynamic>? resumeState,
    Object? response = _unset,
  }) {
    return UploadTask(
      id: id,
      filePaths: filePaths ?? this.filePaths,
      url: url ?? this.url,
      method: method ?? this.method,
      headers: headers ?? this.headers,
      data: data ?? this.data,
      fileFieldName: fileFieldName ?? this.fileFieldName,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      protocol: protocol ?? this.protocol,
      customAdapterId: customAdapterId ?? this.customAdapterId,
      totalBytes: totalBytes ?? this.totalBytes,
      uploadedBytes: uploadedBytes ?? this.uploadedBytes,
      speed: speed ?? this.speed,
      eta: identical(eta, _unset) ? this.eta : eta as Duration?,
      retryCount: retryCount ?? this.retryCount,
      maxRetries: maxRetries ?? this.maxRetries,
      error: identical(error, _unset) ? this.error : error as String?,
      lastStatusCode: identical(lastStatusCode, _unset)
          ? this.lastStatusCode
          : lastStatusCode as int?,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      completedAt: identical(completedAt, _unset)
          ? this.completedAt
          : completedAt as DateTime?,
      nextAttemptAt: identical(nextAttemptAt, _unset)
          ? this.nextAttemptAt
          : nextAttemptAt as DateTime?,
      tag: tag ?? this.tag,
      metadata: metadata ?? this.metadata,
      resumeState: resumeState ?? this.resumeState,
      response: identical(response, _unset) ? this.response : response,
    );
  }

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  /// JSON for persistence. Header keys in [redactHeaders] (lower-case) are
  /// dropped so secrets never reach disk.
  Map<String, dynamic> toJson({
    Set<String> redactHeaders = const {},
    bool includeResponse = true,
  }) {
    final safeHeaders = <String, String>{
      for (final entry in headers.entries)
        if (!redactHeaders.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
    return <String, dynamic>{
      'v': 1,
      'id': id,
      'filePaths': filePaths,
      'url': url,
      'method': method,
      'headers': safeHeaders,
      'data': _jsonSafe(data),
      'fileFieldName': fileFieldName,
      'priority': priority.name,
      'status': status.name,
      'protocol': protocol.name,
      'customAdapterId': customAdapterId,
      'totalBytes': totalBytes,
      'uploadedBytes': uploadedBytes,
      'retryCount': retryCount,
      'maxRetries': maxRetries,
      'error': error,
      'lastStatusCode': lastStatusCode,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'nextAttemptAt': nextAttemptAt?.toIso8601String(),
      'tag': tag,
      'metadata': _jsonSafe(metadata),
      'resumeState': _jsonSafe(resumeState),
      if (includeResponse) 'response': _jsonSafe(response),
    };
  }

  factory UploadTask.fromJson(Map<String, dynamic> json) {
    List<String> paths;
    final rawPaths = json['filePaths'];
    if (rawPaths is List) {
      paths = rawPaths.map((e) => e.toString()).toList();
    } else if (json['filePath'] is String &&
        (json['filePath'] as String).isNotEmpty) {
      paths = [json['filePath'] as String];
    } else {
      paths = const [];
    }

    return UploadTask(
      id: json['id'] as String,
      filePaths: paths,
      url: json['url'] as String? ?? '',
      method: json['method'] as String? ?? 'POST',
      headers: _stringMap(json['headers']),
      data: _dynamicMap(json['data']),
      fileFieldName: json['fileFieldName'] as String? ?? 'file',
      priority: TaskPriority.values.asNameMap()[json['priority']] ??
          TaskPriority.normal,
      status: UploadStatus.values.asNameMap()[json['status']] ??
          UploadStatus.enqueued,
      protocol: UploadProtocol.parse(json['protocol']),
      customAdapterId: json['customAdapterId'] as String?,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      uploadedBytes: (json['uploadedBytes'] as num?)?.toInt() ?? 0,
      retryCount: (json['retryCount'] as num?)?.toInt() ?? 0,
      maxRetries: (json['maxRetries'] as num?)?.toInt(),
      error: json['error'] as String?,
      lastStatusCode: (json['lastStatusCode'] as num?)?.toInt(),
      createdAt: _date(json['createdAt']),
      updatedAt: _date(json['updatedAt']),
      completedAt: _date(json['completedAt']),
      nextAttemptAt: _date(json['nextAttemptAt']),
      tag: json['tag'] as String?,
      metadata: _dynamicMap(json['metadata']),
      resumeState: _dynamicMap(json['resumeState']),
      response: json['response'],
    );
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return value.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  static Map<String, dynamic> _dynamicMap(Object? value) {
    if (value is! Map) return const {};
    return value.map((k, v) => MapEntry(k.toString(), v));
  }

  /// Keeps JSON-encodable values as-is; stringifies anything else so one odd
  /// response body can never break persistence for the whole queue.
  static Object? _jsonSafe(Object? value) {
    if (value == null) return null;
    try {
      jsonEncode(value);
      return value;
    } catch (_) {
      return value.toString();
    }
  }

  /// "12.4 MB"-style formatting.
  static String formatBytes(num bytes, [int decimals = 1]) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return unit == 0
        ? '${value.round()} B'
        : '${value.toStringAsFixed(decimals)} ${units[unit]}';
  }

  @override
  String toString() =>
      'UploadTask($id, $fileName, ${protocol.name}, ${status.name}, $progressPercent%)';
}
