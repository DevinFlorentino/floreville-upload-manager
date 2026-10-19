// End-to-end: the real engine, real adapters, real Dio and the real
// FileQueueStorage, talking HTTP to MockUploadServer on loopback.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:floreville_upload_manager/floreville_upload_manager.dart';
import 'package:floreville_upload_manager/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const _e2eRetry = RetryPolicy(
  maxRetries: 3,
  initialDelay: Duration(milliseconds: 100),
  maxDelay: Duration(seconds: 2),
  jitter: 0,
);

Future<File> randomFile(Directory dir, String name, int size,
    {int seed = 1}) async {
  final random = Random(seed);
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = random.nextInt(256);
  }
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

void main() {
  late MockUploadServer server;
  late Directory dir;
  late ManualConnectivityMonitor connectivity;
  final engines = <UploadEngine>[];

  UploadEngine newEngine({
    HeaderProvider? headerProvider,
    List<UploadAdapter> adapters = const [],
    String storageDir = 'queue',
  }) {
    final engine = UploadEngine(
      storage: FileQueueStorage(directoryPath: '${dir.path}/$storageDir'),
      connectivityMonitor: connectivity,
      retryPolicy: _e2eRetry,
      headerProvider: headerProvider,
      notificationConfig: NotificationConfig.disabled,
    )..registerAdapters(adapters);
    engines.add(engine);
    return engine;
  }

  setUp(() async {
    server = await MockUploadServer.start();
    dir = await Directory.systemTemp.createTemp('fum_e2e_');
    connectivity = ManualConnectivityMonitor();
  });

  tearDown(() async {
    for (final engine in engines) {
      await engine.dispose();
    }
    engines.clear();
    await server.close();
    await dir.delete(recursive: true);
  });

  group('standard', () {
    test('multipart upload delivers identical bytes and form fields', () async {
      final file = await randomFile(dir, 'photo.jpg', 300 * 1024);
      final engine = newEngine();
      final progress = <double>[];

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: server.url('/upload'),
        data: {
          'albumId': '42',
          'tags': ['a', 'b']
        },
        onProgress: (p, _, __) => progress.add(p),
      );
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);

      final stored = server.object('photo.jpg')!;
      expect(stored.bytes, await file.readAsBytes());
      expect(stored.contentType, 'image/jpeg');
      expect(stored.fields['albumId'], '42');
      expect((done.response as Map)['files'], hasLength(1));
      expect(progress.last, 1.0);
    });

    test('uploadMultiple sends every file in one request', () async {
      final files = [
        for (var i = 0; i < 3; i++)
          await randomFile(dir, 'doc_$i.pdf', 50 * 1024, seed: i),
      ];
      final engine = newEngine();

      final task = await engine.enqueue(
        filePaths: [for (final f in files) f.path],
        url: server.url('/upload'),
      );
      await waitForStatus(engine, task.id, UploadStatus.completed);

      expect(server.events.where((e) => e.path == '/upload'), hasLength(1));
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        expect(server.object(name)!.bytes, await f.readAsBytes());
      }
    });

    test('single-file PUT sends a raw body with the given content type',
        () async {
      final file = await randomFile(dir, 'clip.bin', 200 * 1024);
      final engine = newEngine();

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: server.url('/objects/clip.mp4'),
        method: 'PUT',
        metadata: {'contentType': 'video/mp4'},
      );
      await waitForStatus(engine, task.id, UploadStatus.completed);

      final stored = server.object('clip.mp4')!;
      expect(stored.via, 'raw');
      expect(stored.contentType, 'video/mp4');
      expect(stored.bytes, await file.readAsBytes());
    });
  });

  group('retries', () {
    test('503s are retried with backoff until the upload succeeds', () async {
      final file = await randomFile(dir, 'a.txt', 10 * 1024);
      server.failNext(2, status: 503);
      final engine = newEngine();

      final task = await engine
          .enqueue(filePaths: [file.path], url: server.url('/upload'));
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);

      expect(done.retryCount, 2);
      expect(server.events.map((e) => e.status), [503, 503, 201]);
      expect(server.object('a.txt')!.bytes, await file.readAsBytes());
    });

    test('429 Retry-After is honoured', () async {
      final file = await randomFile(dir, 'b.txt', 1024);
      server.failNext(1, status: 429, retryAfter: const Duration(seconds: 1));
      final engine = newEngine();

      final task = await engine
          .enqueue(filePaths: [file.path], url: server.url('/upload'));
      await waitForStatus(engine, task.id, UploadStatus.completed);

      final gap = server.events[1].at.difference(server.events[0].at);
      expect(gap, greaterThanOrEqualTo(const Duration(milliseconds: 900)));
    });

    test('a non-retryable 4xx fails without retrying', () async {
      final file = await randomFile(dir, 'c.txt', 1024);
      final engine = newEngine();
      final reported = Completer<Object>();

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: server.url('/no-such-endpoint'),
        onError: (_, e) => reported.complete(e),
      );
      final failed = await waitForStatus(engine, task.id, UploadStatus.failed);

      expect(failed.lastStatusCode, 404);
      expect(failed.retryCount, 0);
      expect(await reported.future, isA<UploadException>());
      expect(server.events, hasLength(1));
    });

    test('a dropped connection mid-transfer is retried', () async {
      final file = await randomFile(dir, 'd.bin', 512 * 1024);
      server.dropNextConnection(afterBytes: 100 * 1024);
      final engine = newEngine();

      final task = await engine
          .enqueue(filePaths: [file.path], url: server.url('/upload'));
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);

      expect(done.retryCount, 1);
      expect(server.events.first.note, 'connection dropped');
      expect(server.object('d.bin')!.bytes, await file.readAsBytes());
    });

    test('an expired token is refreshed via HeaderProvider after a 401',
        () async {
      final file = await randomFile(dir, 'e.txt', 1024);
      server.requireAuth = true;
      var cached = server.validToken;
      var refreshes = 0;
      final engine = newEngine(headerProvider: (task) async {
        if (task.lastStatusCode == 401) {
          refreshes++;
          cached = server.validToken; // "call the auth server"
        }
        return {'Authorization': 'Bearer $cached'};
      });

      server.rotateToken(); // the cached token is now stale
      final task = await engine
          .enqueue(filePaths: [file.path], url: server.url('/upload'));
      await waitForStatus(engine, task.id, UploadStatus.completed);

      expect(refreshes, 1);
      expect(server.events.map((e) => e.status), [401, 201]);
    });

    test('the Authorization header is never written to the queue file',
        () async {
      final file = await randomFile(dir, 'f.txt', 1024);
      server.requireAuth = true;
      final engine = newEngine(
        headerProvider: (_) async =>
            {'Authorization': 'Bearer ${server.validToken}'},
      );

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: server.url('/upload'),
        headers: const {'Authorization': 'Bearer secret-at-enqueue'},
      );
      await waitForStatus(engine, task.id, UploadStatus.completed);
      await engine.dispose();

      final queueFile = File('${dir.path}/queue/floreville_upload_queue.json');
      final json = await queueFile.readAsString();
      expect(json, contains(task.id));
      expect(json, isNot(contains('secret-at-enqueue')));
      expect(json, isNot(contains(server.validToken)));
    });
  });

  group('resumable', () {
    const chunk = 128 * 1024;
    final adapter = [ResumableUploadAdapter(chunkSize: chunk)];

    test('pause keeps the server offset; resume sends only the rest', () async {
      final file = await randomFile(dir, 'movie.mov', 10 * chunk);
      server.throttleBytesPerSecond = 2 * 1024 * 1024;
      final engine = newEngine(adapters: adapter);

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: server.url('/resumable/movie'),
        method: 'PUT',
        protocol: UploadProtocol.resumable,
      );
      await waitForTask(engine, task.id,
          (t) => (t.resumeState['offset'] as int? ?? 0) >= 3 * chunk,
          reason: '3 chunks confirmed');
      await engine.pause(task.id);
      final paused = await waitForStatus(engine, task.id, UploadStatus.paused);
      final offset = paused.resumeState['offset'] as int;
      // The chunk in flight at pause time may still drain into the server.
      expect(server.resumableOffset('movie'), anyOf(offset, offset + chunk));

      server.throttleBytesPerSecond = null;
      final before = server.events.length;
      await engine.resume(task.id);
      await waitForStatus(engine, task.id, UploadStatus.completed);

      final afterResume = server.events.skip(before);
      final resent = afterResume.fold<int>(0, (sum, e) => sum + e.bytes);
      // Never restarts from 0: at most the interrupted chunk is sent twice.
      expect(resent, lessThanOrEqualTo(10 * chunk - offset + chunk));
      expect(server.object('movie')!.bytes, await file.readAsBytes());
    });

    test('an app kill mid-upload resumes from the checkpoint on relaunch',
        () async {
      final file = await randomFile(dir, 'big.mov', 16 * chunk);
      server.throttleBytesPerSecond = 2 * 1024 * 1024;
      final first = newEngine(adapters: adapter);

      final task = await first.enqueue(
        filePaths: [file.path],
        url: server.url('/resumable/big'),
        method: 'PUT',
        protocol: UploadProtocol.resumable,
      );
      await waitForTask(first, task.id,
          (t) => (t.resumeState['offset'] as int? ?? 0) >= 4 * chunk,
          reason: 'checkpoint');
      await first.dispose(); // the process "dies"

      server.throttleBytesPerSecond = null;
      final relaunched = newEngine(adapters: [
        ResumableUploadAdapter(chunkSize: chunk),
      ]);
      await relaunched.init();
      final restored = relaunched.getTask(task.id)!;
      expect(restored.resumeState['offset'], greaterThanOrEqualTo(4 * chunk));

      await waitForStatus(relaunched, task.id, UploadStatus.completed);
      final total = server.events.fold<int>(0, (sum, e) => sum + e.bytes);
      // Allow one in-flight chunk to be re-sent; never the whole file again.
      expect(total, lessThanOrEqualTo(16 * chunk + chunk));
      expect(server.object('big')!.bytes, await file.readAsBytes());
    });

    test('going offline mid-upload waits without spending a retry', () async {
      final file = await randomFile(dir, 'net.bin', 8 * chunk);
      server.throttleBytesPerSecond = 1024 * 1024;
      final engine = newEngine(adapters: adapter);

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: server.url('/resumable/net'),
        method: 'PUT',
        protocol: UploadProtocol.resumable,
      );
      await waitForTask(engine, task.id,
          (t) => (t.resumeState['offset'] as int? ?? 0) >= chunk,
          reason: 'first chunk');
      connectivity.setOnline(false);
      final waiting =
          await waitForStatus(engine, task.id, UploadStatus.enqueued);
      expect(waiting.retryCount, 0);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.getTask(task.id)!.status, UploadStatus.enqueued);

      server.throttleBytesPerSecond = null;
      connectivity.setOnline(true);
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);
      expect(done.retryCount, 0);
      expect(server.object('net')!.bytes, await file.readAsBytes());
    });

    test('a dropped chunk resumes from the offset the server reports',
        () async {
      final file = await randomFile(dir, 'drop.bin', 6 * chunk);
      final engine = newEngine(adapters: adapter);
      server.dropNextConnection(afterBytes: 10); // first chunk dies

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: server.url('/resumable/drop'),
        method: 'PUT',
        protocol: UploadProtocol.resumable,
      );
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);
      expect(done.retryCount, 1);
      expect(server.object('drop')!.bytes, await file.readAsBytes());
    });
  });

  group('s3 multipart', () {
    const mb = 1024 * 1024;
    late List<UploadAdapter> s3;

    setUp(() {
      s3 = [
        S3MultipartUploadAdapter(
          signer: HttpS3MultipartSigner(baseUrl: server.url('/s3')),
          partSize: 5 * mb,
        ),
      ];
    });

    test('initiate → presigned parts → complete reassembles the file',
        () async {
      final file = await randomFile(dir, 'video.mp4', 12 * mb);
      final engine = newEngine(adapters: s3);

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: 's3',
        protocol: UploadProtocol.s3Multipart,
        metadata: {'contentType': 'video/mp4'},
      );
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);

      final key = (done.response as Map)['key'] as String;
      final stored = server.object(key)!;
      expect(stored.via, 's3');
      expect(stored.contentType, 'video/mp4');
      expect(stored.bytes, await file.readAsBytes());
      expect(server.events.where((e) => e.path.startsWith('/bucket/')),
          hasLength(3));
      expect(server.openS3Sessions, 0);
    });

    test('pause after a part; resume uploads only the remaining parts',
        () async {
      final file = await randomFile(dir, 'long.mp4', 11 * mb);
      server.throttleBytesPerSecond = 40 * mb;
      final engine = newEngine(adapters: s3);

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: 's3',
        protocol: UploadProtocol.s3Multipart,
      );
      await waitForTask(engine, task.id,
          (t) => (t.resumeState['parts'] as List? ?? const []).isNotEmpty,
          reason: 'first part');
      await engine.pause(task.id);
      final paused = await waitForStatus(engine, task.id, UploadStatus.paused);
      final partsDone = (paused.resumeState['parts'] as List).length;

      server.throttleBytesPerSecond = null;
      await engine.resume(task.id);
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);

      final signed =
          server.events.where((e) => e.path == '/s3/sign-part').length;
      final initiated =
          server.events.where((e) => e.path == '/s3/initiate').length;
      expect(initiated, 1);
      // 3 parts total; at most one interrupted part is signed twice.
      expect(signed, lessThanOrEqualTo(3 + 1));
      expect(partsDone, greaterThanOrEqualTo(1));
      final key = (done.response as Map)['key'] as String;
      expect(server.object(key)!.bytes, await file.readAsBytes());
    });

    test('an expired presigned URL (403) is re-signed and retried', () async {
      final file = await randomFile(dir, 'exp.mp4', 6 * mb);
      server.presignTtl = const Duration(seconds: -1);
      late StreamSubscription<MockServerEvent> sub;
      sub = server.eventStream.listen((e) {
        if (e.status == 403) {
          server.presignTtl = const Duration(minutes: 15);
          unawaited(sub.cancel());
        }
      });
      final engine = newEngine(adapters: s3);

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: 's3',
        protocol: UploadProtocol.s3Multipart,
      );
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);

      expect(done.retryCount, 1);
      expect(server.events.where((e) => e.status == 403), hasLength(1));
      final key = (done.response as Map)['key'] as String;
      expect(server.object(key)!.bytes, await file.readAsBytes());
    });

    test('cancel aborts the multipart session on the server', () async {
      final file = await randomFile(dir, 'cancel.mp4', 11 * mb);
      server.throttleBytesPerSecond = 20 * mb;
      final engine = newEngine(adapters: s3);

      final task = await engine.enqueue(
        filePaths: [file.path],
        url: 's3',
        protocol: UploadProtocol.s3Multipart,
      );
      await waitForTask(
          engine, task.id, (t) => t.resumeState['uploadId'] != null,
          reason: 'session opened');
      expect(server.openS3Sessions, 1);

      await engine.cancel(task.id);
      await waitForStatus(engine, task.id, UploadStatus.cancelled);
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (server.openS3Sessions > 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.openS3Sessions, 0);
      expect(server.events.any((e) => e.path == '/s3/abort'), isTrue);
      expect(server.objects, isEmpty);
    });
  });

  test('concurrency limit holds across real uploads', () async {
    server.throttleBytesPerSecond = 2 * 1024 * 1024;
    final engine = UploadEngine(
      storage: InMemoryQueueStorage(),
      connectivityMonitor: connectivity,
      retryPolicy: _e2eRetry,
      maxConcurrentUploads: 2,
      notificationConfig: NotificationConfig.disabled,
    );
    engines.add(engine);
    var peak = 0;
    final sub = engine.statusStream.listen((_) {
      peak = max(peak, engine.summary.activeTasks);
    });

    final tasks = [
      for (var i = 0; i < 5; i++)
        await engine.enqueue(
          filePaths: [
            (await randomFile(dir, 'q$i.bin', 200 * 1024, seed: i)).path
          ],
          url: server.url('/upload'),
          priority: i == 4 ? TaskPriority.critical : TaskPriority.normal,
        ),
    ];
    for (final t in tasks) {
      await waitForStatus(engine, t.id, UploadStatus.completed);
    }
    await sub.cancel();

    expect(peak, 2);
    expect(server.objects, hasLength(5));
    // The critical task jumps the three still-queued normal ones.
    final order = server.objects.map((o) => o.key).toList();
    expect(order.indexOf('q4.bin'), lessThan(order.indexOf('q2.bin')));
  });
}
