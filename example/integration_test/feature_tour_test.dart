// Drives the demo app through every feature in real time — used both as an
// end-to-end UI test and to record the showcase video:
//
//   flutter test integration_test/feature_tour_test.dart -d macos
//
// To record the showcase video, start `python3 tool/record_relay.py out.mp4`
// and add `--dart-define=RECORD_PORT=9777`.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:floreville_upload_manager/floreville_upload_manager.dart';
import 'package:floreville_upload_manager_example/demo_backend.dart';
import 'package:floreville_upload_manager_example/main.dart' as app;
import 'package:floreville_upload_manager_example/main.dart' show DemoApp;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Lets the UI run in real time for [seconds] (keeps frames flowing).
Future<void> hold(WidgetTester tester, double seconds) async {
  final end =
      DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  String reason = 'condition',
  double timeout = 60,
}) async {
  final end = DateTime.now().add(Duration(seconds: timeout.round()));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for $reason');
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> tap(WidgetTester tester, Finder finder,
    {double after = 0.8}) async {
  await tester.tap(finder);
  await hold(tester, after);
}

UploadEngine get engine => DemoBackend.instance.engine;

void say(String? caption) => DemoBackend.instance.caption.value = caption;

/// Streams the app's own frames to `tool/record_relay.py` (which pipes them
/// into ffmpeg) — no OS screen-recording permission and almost no disk.
class FrameRecorder {
  FrameRecorder(this.port, {this.fps = 20, this.pixelRatio = 1.25});

  final int port;
  final int fps;
  final double pixelRatio;
  final _clock = Stopwatch();
  Socket? _socket;
  var _running = false;
  var _sent = 0;
  var _captured = 0;
  Future<void>? _loop;

  Future<void> start() async {
    _socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    _running = true;
    _loop = _run();
  }

  Future<void> _run() async {
    final interval = Duration(microseconds: 1000000 ~/ fps);
    Uint8List? pending;
    final captureTime = Stopwatch();
    while (_running) {
      final boundary = DemoApp.screenKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      Uint8List? frame;
      if (boundary != null && !boundary.debugNeedsPaint) {
        captureTime.start();
        final image = await boundary.toImage(pixelRatio: pixelRatio);
        final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        captureTime.stop();
        if (pending == null) {
          final header = ByteData(12)
            ..setUint32(0, image.width, Endian.little)
            ..setUint32(4, image.height, Endian.little)
            ..setUint32(8, fps, Endian.little);
          _socket!.add(header.buffer.asUint8List());
          _clock.start();
        }
        image.dispose();
        frame = rgba!.buffer.asUint8List();
        _captured++;
      }
      if (frame != null) {
        // Send the previous frame with how many slots it covered, so the
        // relay can repeat it and playback stays real time.
        final due = _clock.elapsedMicroseconds ~/ interval.inMicroseconds + 1;
        if (pending != null) {
          final repeat = (due - _sent).clamp(1, 1 << 30);
          await _send(pending, repeat);
        }
        pending = frame;
      }
      final wait = Duration(microseconds: _sent * interval.inMicroseconds) +
          interval -
          _clock.elapsed;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    if (pending != null) await _send(pending, fps); // hold the last frame 1s
    _avgCaptureMs =
        _captured == 0 ? 0 : captureTime.elapsedMilliseconds / _captured;
  }

  double _avgCaptureMs = 0;

  Future<void> _send(Uint8List frame, int repeat) async {
    final count = ByteData(4)..setUint32(0, repeat, Endian.little);
    _socket!
      ..add(count.buffer.asUint8List())
      ..add(frame);
    _sent += repeat;
    await _socket!.flush();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _loop;
    await _socket?.close();
    debugPrint('RECORDING $_sent frames ($_captured unique, '
        'capture ${_avgCaptureMs.toStringAsFixed(0)} ms avg) over '
        '${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
  }
}

/// The most recently added task whose file name starts with [prefix].
UploadTask taskNamed(String prefix) => engine.tasks
    .where((t) => t.fileName.startsWith(prefix))
    .reduce((a, b) => a.createdAt.isAfter(b.createdAt) ? a : b);

bool allSettled() => engine.tasks.every((t) => t.status.isTerminal);

Finder tileButton(UploadTask task, String tooltip) => find.descendant(
      of: find.byKey(ValueKey(task.id)),
      matching: find.byTooltip(tooltip),
    );

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('feature tour', (tester) async {
    await app.main();
    const port = int.fromEnvironment('RECORD_PORT');
    if (port > 0) {
      final r = FrameRecorder(port);
      await r.start();
      addTearDown(r.stop); // also on failure, or the capture loop lingers
    }
    say('Floreville Upload Manager — real HTTP uploads to a local mock server');
    await hold(tester, 3.5);
    final backend = DemoBackend.instance;
    final server = backend.server;
    expect(find.byKey(const Key('empty-queue')), findsOneWidget);

    // 1. Multipart photo + a 3-file bundle in one request.
    say('Multipart upload + a 3-file bundle in one request');
    await tap(tester, find.byKey(const Key('add-photo')), after: 0.6);
    await tap(tester, find.byKey(const Key('add-bundle')));
    await waitUntil(tester, allSettled, reason: 'photo + bundle');
    expect(engine.summary.completedTasks, 2);
    await hold(tester, 2);

    // 2. Large files: resumable chunks and S3 multipart, side by side.
    say('Big files: Content-Range chunks and S3 multipart, 2 at a time');
    await tap(tester, find.byKey(const Key('add-resumable')), after: 0.6);
    await tap(tester, find.byKey(const Key('add-s3')), after: 3);

    // Pause and resume the chunked upload — it continues from its checkpoint.
    final clip = taskNamed('clip_');
    say('Pause → resume continues from the last confirmed chunk');
    await tap(tester, tileButton(clip, 'Pause'), after: 2.5);
    expect(engine.getTask(clip.id)!.status, UploadStatus.paused);
    final pausedAt = engine.getTask(clip.id)!.uploadedBytes;
    expect(pausedAt, greaterThan(0));
    await tap(tester, tileButton(clip, 'Resume'), after: 2.5);

    // 3. Network loss: everything waits, no retries are spent.
    say('Network drops → uploads wait without spending retries');
    await tap(tester, find.byKey(const Key('network-switch')), after: 3.5);
    expect(engine.summary.isConnected, isFalse);
    expect(engine.summary.activeTasks, 0);
    await tap(tester, find.byKey(const Key('network-switch')), after: 2);
    await waitUntil(tester, allSettled, reason: 'videos');
    expect(engine.getTask(clip.id)!.retryCount, 0);
    await hold(tester, 2);

    // 4. Server errors: two 503s, retried with exponential backoff.
    say('Server returns 503 twice → exponential backoff, then success');
    await tap(tester, find.byKey(const Key('fault-503')), after: 1.2);
    await tap(tester, find.byKey(const Key('add-photo')));
    await waitUntil(tester, allSettled, reason: '503 retries');
    expect(taskNamed('IMG_').retryCount, 2);
    await hold(tester, 2);

    // 5. Expired token: 401 → HeaderProvider refreshes → success.
    say('Token expires → 401 → HeaderProvider refreshes it → retried');
    await tap(tester, find.byKey(const Key('fault-token')), after: 1.2);
    await tap(tester, find.byKey(const Key('add-photo')));
    await waitUntil(tester, allSettled, reason: 'token refresh');
    expect(taskNamed('IMG_').status, UploadStatus.completed);
    await hold(tester, 2);

    // 6. Priority: a critical receipt jumps the queued photos.
    say('Priority queue: a critical receipt jumps the waiting photos');
    await tap(tester, find.byKey(const Key('add-resumable')), after: 0.4);
    await tap(tester, find.byKey(const Key('add-s3')), after: 0.4);
    await tap(tester, find.byKey(const Key('add-photo')), after: 0.4);
    await tap(tester, find.byKey(const Key('add-photo')), after: 0.4);
    await tap(tester, find.byKey(const Key('add-receipt')), after: 2.5);
    final receipt = taskNamed('receipt_');
    final queued = engine.tasks
        .where((t) => t.status == UploadStatus.enqueued)
        .map((t) => t.id)
        .toList();
    expect(queued.first, receipt.id);

    // 7. The OS kills the app mid-upload; relaunch resumes from checkpoints.
    say('App killed mid-upload → relaunch restores the queue from disk');
    final bigClip = taskNamed('clip_');
    await waitUntil(
        tester, () => engine.getTask(bigClip.id)!.resumeState['offset'] != null,
        reason: 'resumable checkpoint');
    await tap(tester, find.byKey(const Key('kill-relaunch')), after: 1.5);
    final restored = engine.getTask(bigClip.id)!;
    expect(restored.uploadedBytes, greaterThan(0));
    say('…and carries on from each checkpoint instead of 0 %');
    await hold(tester, 3);

    // 8. A dropped connection mid-transfer is retried transparently.
    say('Connection dropped mid-transfer → retried transparently');
    await tap(tester, find.byKey(const Key('fault-drop')), after: 1.2);
    await tap(tester, find.byKey(const Key('add-photo')));
    await waitUntil(tester, allSettled, reason: 'everything', timeout: 120);
    expect(
        engine.tasks.every((t) => t.status == UploadStatus.completed), isTrue);
    await hold(tester, 2.5);

    // Every byte the server stored matches the file on disk.
    final files = '${backend.workDir.path}/files';
    for (final object in server.objects) {
      final local = File('$files/${object.key.split('/').last}');
      expect(object.bytes, await local.readAsBytes(), reason: object.key);
    }
    expect(server.objects, hasLength(engine.tasks.length + 2)); // bundle = 3

    say('${server.objects.length} files on the server — every byte verified');
    await hold(tester, 3);
    say(null);
    await tap(tester, find.byKey(const Key('clear-finished')), after: 2.5);
    expect(find.byKey(const Key('empty-queue')), findsOneWidget);
  });
}
