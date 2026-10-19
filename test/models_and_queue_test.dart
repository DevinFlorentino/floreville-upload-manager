import 'package:floreville_upload_manager/floreville_upload_manager.dart';
import 'package:flutter_test/flutter_test.dart';

UploadTask task(
  String id, {
  TaskPriority priority = TaskPriority.normal,
  UploadStatus status = UploadStatus.enqueued,
  DateTime? createdAt,
  DateTime? nextAttemptAt,
  int total = 0,
  int uploaded = 0,
}) =>
    UploadTask(
      id: id,
      filePaths: ['/tmp/$id.bin'],
      url: 'https://api.test',
      priority: priority,
      status: status,
      createdAt: createdAt,
      nextAttemptAt: nextAttemptAt,
      totalBytes: total,
      uploadedBytes: uploaded,
    );

void main() {
  group('UploadTask', () {
    test('copyWith can clear nullable fields', () {
      final t = task('a').copyWith(
        error: 'boom',
        eta: const Duration(seconds: 3),
        nextAttemptAt: DateTime.now(),
        lastStatusCode: 500,
      );
      final cleared = t.copyWith(
          error: null, eta: null, nextAttemptAt: null, lastStatusCode: null);
      expect(cleared.error, isNull);
      expect(cleared.eta, isNull);
      expect(cleared.nextAttemptAt, isNull);
      expect(cleared.lastStatusCode, isNull);

      // Omitted = unchanged.
      expect(t.copyWith(speed: 1).error, 'boom');
    });

    test('JSON round-trip keeps state and enums by name', () {
      final original = UploadTask(
        id: 'x',
        filePaths: const ['/a.jpg', '/b.jpg'],
        url: 'https://api.test',
        method: 'PUT',
        headers: const {'X-Trace': '1'},
        data: const {
          'album': 7,
          'tags': ['a', 'b']
        },
        priority: TaskPriority.high,
        status: UploadStatus.paused,
        protocol: UploadProtocol.resumable,
        totalBytes: 10,
        uploadedBytes: 4,
        retryCount: 2,
        maxRetries: 9,
        error: 'e',
        nextAttemptAt: DateTime.utc(2030),
        tag: 'photos',
        metadata: const {'k': 'v'},
        resumeState: const {'offset': 4},
        response: const {'id': 1},
      );
      final copy = UploadTask.fromJson(original.toJson());
      expect(copy.filePaths, original.filePaths);
      expect(copy.method, 'PUT');
      expect(copy.headers, original.headers);
      expect(copy.data, original.data);
      expect(copy.priority, TaskPriority.high);
      expect(copy.status, UploadStatus.paused);
      expect(copy.protocol, UploadProtocol.resumable);
      expect(copy.uploadedBytes, 4);
      expect(copy.retryCount, 2);
      expect(copy.maxRetries, 9);
      expect(copy.nextAttemptAt, DateTime.utc(2030));
      expect(copy.resumeState, {'offset': 4});
      expect(copy.response, {'id': 1});
      expect(copy.isMultiFile, isTrue);
      expect(copy.fileName, '2 files');
    });

    test('toJson redacts sensitive headers case-insensitively', () {
      final t = task('h').copyWith(headers: {
        'Authorization': 'Bearer secret',
        'APIKEY': 'anon',
        'X-Keep': 'yes',
      });
      final json = t.toJson(redactHeaders: kSensitiveHeaders);
      expect(json['headers'], {'X-Keep': 'yes'});
    });

    test('unknown persisted enum values fall back safely', () {
      final json = task('u').toJson()
        ..['status'] = 'exploded'
        ..['priority'] = 'urgent'
        ..['protocol'] = 'tus';
      final t = UploadTask.fromJson(json);
      expect(t.status, UploadStatus.enqueued);
      expect(t.priority, TaskPriority.normal);
      expect(t.protocol, UploadProtocol.standard);
    });

    test('non-encodable response is stringified, not fatal', () {
      final t = task('r').copyWith(response: Object());
      expect(t.toJson()['response'], isA<String>());
    });

    test('formatting helpers', () {
      expect(UploadTask.formatBytes(0), '0 B');
      expect(UploadTask.formatBytes(512), '512 B');
      expect(UploadTask.formatBytes(1536), '1.5 KB');
      expect(UploadTask.formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(task('e').copyWith(eta: const Duration(seconds: 75)).formattedEta,
          '1m 15s');
    });
  });

  group('UploadQueue', () {
    test('pendingReady orders by priority then age and skips backoff', () {
      final base = DateTime(2026);
      final q = UploadQueue()
        ..put(task('low', priority: TaskPriority.low, createdAt: base))
        ..put(task('n1', createdAt: base.add(const Duration(seconds: 1))))
        ..put(task('n2', createdAt: base.add(const Duration(seconds: 2))))
        ..put(task('crit',
            priority: TaskPriority.critical,
            createdAt: base.add(const Duration(seconds: 3))))
        ..put(task('later',
            priority: TaskPriority.critical,
            nextAttemptAt: DateTime.now().add(const Duration(hours: 1))))
        ..put(task('paused', status: UploadStatus.paused));

      expect(q.pendingReady(DateTime.now()).map((t) => t.id),
          ['crit', 'n1', 'n2', 'low']);
    });

    test('summary counts and bytes', () {
      final q = UploadQueue()
        ..put(task('r', status: UploadStatus.running, total: 100, uploaded: 50))
        ..put(task('d',
            status: UploadStatus.completed, total: 100, uploaded: 100))
        ..put(task('c', status: UploadStatus.cancelled, total: 1000))
        ..put(task('w',
            total: 100,
            nextAttemptAt: DateTime.now().add(const Duration(minutes: 1))));
      final s = q.summarize(isConnected: true);
      expect(s.activeTasks, 1);
      expect(s.completedTasks, 1);
      expect(s.cancelledTasks, 1);
      expect(s.enqueuedTasks, 1);
      expect(s.waitingForRetry, 1);
      expect(s.totalBytes, 300); // cancelled excluded
      expect(s.uploadedBytes, 150);
      expect(s.overallProgressPercent, 50);
    });

    test('removeTerminal drops completed and cancelled only', () {
      final q = UploadQueue()
        ..put(task('a', status: UploadStatus.completed))
        ..put(task('b', status: UploadStatus.cancelled))
        ..put(task('c', status: UploadStatus.failed));
      expect(q.removeTerminal()..sort(), ['a', 'b']);
      expect(q.values.single.id, 'c');
    });
  });

  test('SpeedTracker smooths and estimates ETA', () {
    final start = DateTime(2026);
    final tracker = SpeedTracker(start: start);
    tracker.sample(1000, start.add(const Duration(seconds: 1)));
    expect(tracker.bytesPerSecond, 1000);
    tracker.sample(4000, start.add(const Duration(seconds: 2)));
    expect(tracker.bytesPerSecond, closeTo(1600, 0.01)); // 0.7*1000 + 0.3*3000
    expect(tracker.etaFor(1600), const Duration(seconds: 1));
    // Restart from a lower offset: rebased, not negative.
    tracker.sample(0, start.add(const Duration(seconds: 3)));
    expect(tracker.bytesPerSecond, closeTo(1600, 0.01));
  });
}
