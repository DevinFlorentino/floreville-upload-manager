import '../models/upload_task.dart';

/// Header names (lower-case) never written to disk by default.
const Set<String> kSensitiveHeaders = {
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
  'x-api-key',
  'apikey', // Supabase anon/service keys
  'x-amz-security-token',
  'x-goog-api-key',
};

/// Durable task store. Implement this to keep the queue in SQLite, Hive,
/// Isar, etc.
abstract class QueueStorage {
  Future<void> init();
  Future<List<UploadTask>> loadAll();
  Future<void> saveTask(UploadTask task);
  Future<void> saveAll(List<UploadTask> tasks);
  Future<void> deleteTask(String taskId);
  Future<void> clearAll();
  Future<void> close();
}
