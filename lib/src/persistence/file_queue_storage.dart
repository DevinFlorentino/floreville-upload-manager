import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/upload_task.dart';
import 'queue_storage.dart';

/// JSON-file task store.
///
/// * **Atomic:** writes go to `<file>.tmp`, are flushed, then renamed over
///   the real file — a crash mid-write never leaves a half-written queue.
/// * **Coalesced:** bursts of saves (progress checkpoints) collapse into one
///   write in flight plus at most one queued write.
/// * **Redacted:** headers in [redactedHeaders] never reach disk.
/// * **Self-healing:** an unreadable file is moved aside as
///   `<file>.corrupt.<timestamp>` and the queue starts empty.
///
/// Default location: the app support directory (not user-visible
/// Documents, and excluded from the iOS Files app).
class FileQueueStorage implements QueueStorage {
  FileQueueStorage({
    this.directoryPath,
    this.fileName = 'floreville_upload_queue.json',
    Set<String> redactedHeaders = kSensitiveHeaders,
    this.persistResponses = true,
  }) : _redacted = redactedHeaders.map((h) => h.toLowerCase()).toSet();

  /// Custom directory; defaults to `getApplicationSupportDirectory()`.
  final String? directoryPath;
  final String fileName;

  /// Set false if server responses may be large or contain personal data.
  final bool persistResponses;

  final Set<String> _redacted;
  final Map<String, UploadTask> _cache = {};
  File? _file;
  bool _dirty = false;
  Future<void>? _flushing;

  @override
  Future<void> init() async {
    final dir = directoryPath != null
        ? Directory(directoryPath!)
        : await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    _file = File(p.join(dir.path, fileName));
    await _load();
  }

  Future<void> _load() async {
    final file = _file!;
    final tmp = File('${file.path}.tmp');
    // A crash after the temp write but before the rename leaves only .tmp.
    final source =
        await file.exists() ? file : (await tmp.exists() ? tmp : null);
    if (source == null) return;

    try {
      final content = await source.readAsString();
      if (content.trim().isEmpty) return;
      final decoded = jsonDecode(content);
      final rows = decoded is Map ? decoded['tasks'] : decoded;
      if (rows is! List) throw const FormatException('Expected a task list');
      _cache.clear();
      for (final row in rows) {
        if (row is Map) {
          final task = UploadTask.fromJson(
            row.map((k, v) => MapEntry(k.toString(), v)),
          );
          _cache[task.id] = task;
        }
      }
    } catch (e) {
      debugPrint('[floreville_upload_manager] Queue file unreadable ($e); '
          'moving it aside and starting empty.');
      try {
        await source.rename(
          '${file.path}.corrupt.${DateTime.now().millisecondsSinceEpoch}',
        );
      } catch (_) {}
      _cache.clear();
    }
  }

  @override
  Future<List<UploadTask>> loadAll() async => _cache.values.toList();

  @override
  Future<void> saveTask(UploadTask task) {
    _cache[task.id] = task;
    return _scheduleFlush();
  }

  @override
  Future<void> saveAll(List<UploadTask> tasks) {
    for (final task in tasks) {
      _cache[task.id] = task;
    }
    return _scheduleFlush();
  }

  @override
  Future<void> deleteTask(String taskId) {
    if (_cache.remove(taskId) == null) return Future.value();
    return _scheduleFlush();
  }

  @override
  Future<void> clearAll() {
    _cache.clear();
    return _scheduleFlush();
  }

  /// Returns a future that completes once a write containing the current
  /// cache state has hit disk.
  Future<void> _scheduleFlush() {
    _dirty = true;
    return _flushing ??= _drain();
  }

  Future<void> _drain() async {
    try {
      while (_dirty) {
        _dirty = false;
        await _write();
      }
    } finally {
      _flushing = null;
    }
  }

  Future<void> _write() async {
    final file = _file;
    if (file == null) return;
    final payload = jsonEncode({
      'version': 1,
      'tasks': _cache.values
          .map((t) => t.toJson(
                redactHeaders: _redacted,
                includeResponse: persistResponses,
              ))
          .toList(),
    });
    final tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(payload, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[floreville_upload_manager] Atomic write failed ($e); '
          'falling back to a direct write.');
      try {
        await file.writeAsString(payload, flush: true);
      } catch (e2) {
        debugPrint('[floreville_upload_manager] Queue write failed: $e2');
      }
    }
  }

  @override
  Future<void> close() async {
    await _flushing;
    _cache.clear();
  }
}
