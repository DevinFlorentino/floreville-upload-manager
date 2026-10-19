import '../models/upload_task.dart';
import 'queue_storage.dart';

/// Non-persistent storage for tests and ephemeral queues.
///
/// Round-trips through JSON (with the same header redaction as the file
/// store) so tests exercise the real serialization path.
class InMemoryQueueStorage implements QueueStorage {
  InMemoryQueueStorage({Set<String> redactedHeaders = kSensitiveHeaders})
      : _redacted = redactedHeaders.map((h) => h.toLowerCase()).toSet();

  final Set<String> _redacted;
  final Map<String, Map<String, dynamic>> _rows = {};

  /// Raw persisted rows — handy for assertions.
  Map<String, Map<String, dynamic>> get rows => Map.unmodifiable(_rows);

  @override
  Future<void> init() async {}

  @override
  Future<List<UploadTask>> loadAll() async =>
      _rows.values.map(UploadTask.fromJson).toList();

  @override
  Future<void> saveTask(UploadTask task) async {
    _rows[task.id] = task.toJson(redactHeaders: _redacted);
  }

  @override
  Future<void> saveAll(List<UploadTask> tasks) async {
    for (final task in tasks) {
      _rows[task.id] = task.toJson(redactHeaders: _redacted);
    }
  }

  @override
  Future<void> deleteTask(String taskId) async => _rows.remove(taskId);

  @override
  Future<void> clearAll() async => _rows.clear();

  @override
  Future<void> close() async {}
}
