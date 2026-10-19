import 'package:floreville_upload_manager/floreville_upload_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('UploadEngine', () {
    late UploadEngine engine;

    tearDown(() async => engine.dispose());

    test('completes a task, stores the response and clears resume state',
        () async {
      UploadTask? succeeded;
      final adapter = FakeAdapter((ctx, _) async {
        await ctx.checkpoint({'offset': 50}, confirmedBytes: 50);
        return succeed(ctx, 1);
      });
      engine = makeEngine(adapters: [adapter]);

      final task = await enqueueFake(engine, onSuccess: (t) => succeeded = t);
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);

      expect(done.response, {'ok': true});
      expect(done.progress, 1.0);
      expect(done.resumeState, isEmpty);
      expect(done.completedAt, isNotNull);
      expect(succeeded?.id, task.id);
      expect(adapter.attempts, 1);
    });

    test('waits out the backoff before retrying (not immediately)', () async {
      final adapter = FakeAdapter((ctx, attempt) async {
        if (attempt == 1) throw connectionError();
        return succeed(ctx, attempt);
      });
      engine = makeEngine(adapters: [adapter]);

      final task = await enqueueFake(engine);
      final waiting = await waitForTask(
        engine,
        task.id,
        (t) => t.retryCount == 1 && t.nextAttemptAt != null,
        reason: 'retry scheduled',
      );
      expect(waiting.status, UploadStatus.enqueued);
      expect(waiting.isWaitingForRetry, isTrue);

      // Initial delay is 60 ms — after 30 ms the second attempt must not
      // have started yet.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(adapter.attempts, 1);

      final done = await waitForStatus(engine, task.id, UploadStatus.completed);
      expect(adapter.attempts, 2);
      expect(done.retryCount, 1);
      expect(done.error, isNull);
    });

    test('fails immediately on a non-retryable 4xx and fires onError once',
        () async {
      var errors = 0;
      final adapter = FakeAdapter(
          (ctx, _) async => throw UploadException.http(400, 'bad request'));
      engine = makeEngine(adapters: [adapter]);

      final task = await enqueueFake(engine, onError: (_, __) => errors++);
      final failed = await waitForStatus(engine, task.id, UploadStatus.failed);

      expect(adapter.attempts, 1);
      expect(errors, 1);
      expect(failed.lastStatusCode, 400);
      expect(failed.error, contains('400'));
    });

    test('gives up after maxRetries', () async {
      final adapter =
          FakeAdapter((ctx, _) async => throw UploadException.http(503, null));
      engine = makeEngine(adapters: [adapter]);

      final task = await enqueueFake(engine);
      final failed = await waitForStatus(engine, task.id, UploadStatus.failed);

      expect(adapter.attempts, 3); // 1 + maxRetries(2)
      expect(failed.retryCount, 2);
    });

    test('pause keeps the checkpoint and resume continues from it', () async {
      final adapter = FakeAdapter((ctx, attempt) async {
        if (attempt == 1) return checkpointThenHang(ctx, 40);
        return succeed(ctx, attempt);
      });
      final storage = InMemoryQueueStorage();
      engine = makeEngine(adapters: [adapter], storage: storage);

      final task = await enqueueFake(engine);
      await waitForTask(engine, task.id, (t) => t.resumeState['offset'] == 40,
          reason: 'checkpoint');

      await engine.pause(task.id);
      final paused = await waitForStatus(engine, task.id, UploadStatus.paused);
      expect(paused.uploadedBytes, 40);
      expect(storage.rows[task.id]!['status'], 'paused');
      expect(storage.rows[task.id]!['resumeState'], {'offset': 40});

      // A paused task is not restarted by the scheduler.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.attempts, 1);

      await engine.resume(task.id);
      await waitForStatus(engine, task.id, UploadStatus.completed);
      expect(adapter.attempts, 2);
      expect(adapter.resumeStatesSeen.last, {'offset': 40});
    });

    test('going offline re-queues without spending a retry; online resumes',
        () async {
      final connectivity = ManualConnectivityMonitor();
      final adapter = FakeAdapter((ctx, attempt) async {
        if (attempt == 1) return checkpointThenHang(ctx, 10);
        return succeed(ctx, attempt);
      });
      engine = makeEngine(adapters: [adapter], connectivity: connectivity);

      final task = await enqueueFake(engine);
      await waitForStatus(engine, task.id, UploadStatus.running);
      await waitForTask(engine, task.id, (t) => t.uploadedBytes == 10);

      connectivity.setOnline(false);
      final waiting =
          await waitForStatus(engine, task.id, UploadStatus.enqueued);
      expect(waiting.retryCount, 0);
      expect(waiting.error, contains('network'));
      expect(engine.summary.isConnected, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.attempts, 1);

      connectivity.setOnline(true);
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);
      expect(done.retryCount, 0);
      expect(adapter.attempts, 2);
    });

    test('tasks added while offline wait for the network', () async {
      final connectivity = ManualConnectivityMonitor(online: false);
      final adapter = FakeAdapter(succeed);
      engine = makeEngine(adapters: [adapter], connectivity: connectivity);

      final task = await enqueueFake(engine);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(adapter.attempts, 0);
      expect(engine.getTask(task.id)!.status, UploadStatus.enqueued);

      connectivity.setOnline(true);
      await waitForStatus(engine, task.id, UploadStatus.completed);
    });

    test('dequeues by priority, then FIFO', () async {
      final connectivity = ManualConnectivityMonitor(online: false);
      final adapter = FakeAdapter(succeed);
      engine = makeEngine(
          adapters: [adapter], connectivity: connectivity, concurrency: 1);

      final low = await enqueueFake(engine, priority: TaskPriority.low);
      final normalA = await enqueueFake(engine);
      final critical =
          await enqueueFake(engine, priority: TaskPriority.critical);
      final normalB = await enqueueFake(engine);

      connectivity.setOnline(true);
      await waitForStatus(engine, low.id, UploadStatus.completed);

      expect(adapter.startedTaskIds,
          [critical.id, normalA.id, normalB.id, low.id]);
    });

    test('respects maxConcurrentUploads', () async {
      var running = 0;
      var peak = 0;
      final adapter = FakeAdapter((ctx, attempt) async {
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        running--;
        return succeed(ctx, attempt);
      });
      engine = makeEngine(adapters: [adapter], concurrency: 2);

      final tasks = [for (var i = 0; i < 5; i++) await enqueueFake(engine)];
      for (final t in tasks) {
        await waitForStatus(engine, t.id, UploadStatus.completed);
      }
      expect(peak, 2);
    });

    test('restores a task that was running when the app died', () async {
      final storage = InMemoryQueueStorage();
      await storage.saveTask(UploadTask(
        id: 'crashed',
        filePaths: const [],
        url: 'https://api.test/upload',
        protocol: UploadProtocol.custom,
        customAdapterId: 'fake',
        status: UploadStatus.running,
        totalBytes: 100,
        uploadedBytes: 30,
        resumeState: const {'offset': 30},
      ));
      final adapter = FakeAdapter(succeed);
      engine = makeEngine(adapters: [adapter], storage: storage);
      await engine.init();

      await waitForStatus(engine, 'crashed', UploadStatus.completed);
      expect(adapter.resumeStatesSeen.single, {'offset': 30});
    });

    test('re-arms a persisted retry backoff after restart', () async {
      final storage = InMemoryQueueStorage();
      await storage.saveTask(UploadTask(
        id: 'later',
        filePaths: const [],
        url: 'https://api.test/upload',
        protocol: UploadProtocol.custom,
        customAdapterId: 'fake',
        retryCount: 1,
        nextAttemptAt: DateTime.now().add(const Duration(milliseconds: 80)),
      ));
      final adapter = FakeAdapter(succeed);
      engine = makeEngine(adapters: [adapter], storage: storage);
      await engine.init();

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(adapter.attempts, 0);
      await waitForStatus(engine, 'later', UploadStatus.completed);
    });

    test('cancel stops the attempt, releases server state, no onError',
        () async {
      var errors = 0;
      final adapter =
          FakeAdapter((ctx, _) async => checkpointThenHang(ctx, 20));
      engine = makeEngine(adapters: [adapter]);

      final task = await enqueueFake(engine, onError: (_, __) => errors++);
      await waitForTask(engine, task.id, (t) => t.uploadedBytes == 20);
      await engine.cancel(task.id);

      final cancelled =
          await waitForStatus(engine, task.id, UploadStatus.cancelled);
      expect(cancelled.resumeState, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(adapter.cancelledTasks.single.id, task.id);
      expect(errors, 0);
    });

    test('deleteTask removes a running task from memory and storage', () async {
      final storage = InMemoryQueueStorage();
      final adapter = FakeAdapter((ctx, _) async => checkpointThenHang(ctx, 5));
      engine = makeEngine(adapters: [adapter], storage: storage);

      final task = await enqueueFake(engine);
      await waitForStatus(engine, task.id, UploadStatus.running);
      await engine.deleteTask(task.id);

      expect(engine.getTask(task.id), isNull);
      expect(storage.rows.containsKey(task.id), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(engine.getTask(task.id), isNull);
    });

    test('HeaderProvider refreshes auth and a 401 is retried once refreshed',
        () async {
      var issued = 0;
      final adapter = FakeAdapter((ctx, attempt) async {
        if (ctx.task.headers['Authorization'] == 'Bearer stale') {
          throw UploadException.http(401, 'expired');
        }
        return succeed(ctx, attempt);
      });
      engine = makeEngine(
        adapters: [adapter],
        headerProvider: (_) async {
          issued++;
          return {
            'Authorization': issued == 1 ? 'Bearer stale' : 'Bearer fresh'
          };
        },
      );

      final task = await enqueueFake(engine, headers: {'X-App': 'floreville'});
      await waitForStatus(engine, task.id, UploadStatus.completed);

      expect(adapter.attempts, 2);
      expect(adapter.headersSeen.last,
          {'X-App': 'floreville', 'Authorization': 'Bearer fresh'});
    });

    test('a 401 without a HeaderProvider fails without retrying', () async {
      final adapter =
          FakeAdapter((ctx, _) async => throw UploadException.http(401, null));
      engine = makeEngine(adapters: [adapter]);
      final task = await enqueueFake(engine);
      await waitForStatus(engine, task.id, UploadStatus.failed);
      expect(adapter.attempts, 1);
    });

    test('pauseAll does not let queued tasks sneak into freed slots', () async {
      final adapter = FakeAdapter((ctx, _) async => checkpointThenHang(ctx, 1));
      engine = makeEngine(adapters: [adapter], concurrency: 1);

      final a = await enqueueFake(engine);
      final b = await enqueueFake(engine);
      final c = await enqueueFake(engine);
      await waitForStatus(engine, a.id, UploadStatus.running);

      await engine.pauseAll();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(adapter.attempts, 1);
      for (final t in [a, b, c]) {
        expect(engine.getTask(t.id)!.status, UploadStatus.paused);
      }
    });

    test('retry() of a failed task resets the retry budget', () async {
      final adapter = FakeAdapter((ctx, attempt) async {
        if (attempt == 1) throw UploadException.http(400, null);
        return succeed(ctx, attempt);
      });
      engine = makeEngine(adapters: [adapter]);

      final task = await enqueueFake(engine);
      await waitForStatus(engine, task.id, UploadStatus.failed);
      await engine.retry(task.id);
      final done = await waitForStatus(engine, task.id, UploadStatus.completed);
      expect(done.retryCount, 0);
      expect(done.lastStatusCode, isNull);
    });

    test('a task for an unregistered adapter fails with a clear message',
        () async {
      engine = makeEngine();
      final task = await engine.enqueue(
        filePaths: const [],
        url: 'https://api.test',
        protocol: UploadProtocol.custom,
        customAdapterId: 'missing',
      );
      final failed = await waitForStatus(engine, task.id, UploadStatus.failed);
      expect(failed.error, contains('No adapter registered'));
    });

    test('rejects missing files at enqueue time', () async {
      engine = makeEngine();
      await expectLater(
        engine.enqueue(
            filePaths: const ['/does/not/exist.bin'], url: 'https://api.test'),
        throwsA(isA<UploadException>()),
      );
    });

    test('summary and streams reflect progress', () async {
      final summaries = <QueueSummary>[];
      final adapter = FakeAdapter(succeed);
      engine = makeEngine(adapters: [adapter]);
      final sub = engine.summaryStream.listen(summaries.add);

      final task = await enqueueFake(engine);
      final statuses = <UploadStatus>[];
      final watchSub =
          engine.watch(task.id).listen((t) => statuses.add(t.status));
      await waitForStatus(engine, task.id, UploadStatus.completed);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(engine.summary.completedTasks, 1);
      expect(engine.summary.overallProgress, 1.0);
      expect(summaries, isNotEmpty);
      expect(statuses.last, UploadStatus.completed);
      await sub.cancel();
      await watchSub.cancel();
    });
  });
}
