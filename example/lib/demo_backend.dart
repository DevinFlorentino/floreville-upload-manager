import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:floreville_upload_manager/floreville_upload_manager.dart';
import 'package:floreville_upload_manager/testing.dart';
import 'package:flutter/foundation.dart';

/// Everything the demo needs besides UI: an in-process HTTP backend, the
/// upload engine wired to it, and real files to upload.
class DemoBackend {
  DemoBackend._(this.server, this.workDir);

  static late DemoBackend instance;

  /// Starts the mock server and the engine. Wipes any queue left over from a
  /// previous launch (its server is gone).
  static Future<DemoBackend> start() async {
    final server = await MockUploadServer.start();
    server
      ..throttleBytesPerSecond = 4 * _mb
      ..requireAuth = true;
    final dir = Directory('${Directory.systemTemp.path}/floreville_demo');
    if (await dir.exists()) await dir.delete(recursive: true);
    await Directory('${dir.path}/files').create(recursive: true);

    final backend = DemoBackend._(server, dir);
    backend._token = server.validToken;
    await backend._initEngine();
    return instance = backend;
  }

  static const _mb = 1024 * 1024;

  final MockUploadServer server;
  final Directory workDir;

  /// Simulated device network; flip it from the UI.
  final ManualConnectivityMonitor connectivity = ManualConnectivityMonitor();

  /// Bumped when the engine is recreated so widgets resubscribe.
  final ValueNotifier<int> generation = ValueNotifier(0);

  /// Narration shown over the UI during the scripted feature tour.
  final ValueNotifier<String?> caption = ValueNotifier(null);

  /// The app's cached access token — refreshed only after a 401, like a real
  /// auth client.
  late String _token;
  var _counter = 0;

  UploadEngine get engine => FlorevilleUploadManager.instance;

  Future<void> _initEngine() => FlorevilleUploadManager.initialize(
        storage: FileQueueStorage(directoryPath: '${workDir.path}/queue'),
        connectivityMonitor: connectivity,
        maxConcurrentUploads: 2,
        retryPolicy: const RetryPolicy(
          maxRetries: 4,
          initialDelay: Duration(seconds: 1),
          maxDelay: Duration(seconds: 8),
        ),
        notificationConfig: NotificationConfig.disabled,
        headerProvider: (task) async {
          if (task.lastStatusCode == 401) _token = server.validToken;
          return {'Authorization': 'Bearer $_token'};
        },
        adapters: [
          ResumableUploadAdapter(chunkSize: 512 * 1024),
          S3MultipartUploadAdapter(
            signer: HttpS3MultipartSigner(baseUrl: server.url('/s3')),
            partSize: 5 * _mb,
          ),
        ],
      );

  /// Simulates the OS killing the app: the engine is torn down mid-upload
  /// and a fresh one restores the queue from disk.
  Future<void> killAndRelaunch() async {
    await FlorevilleUploadManager.reset();
    await _initEngine();
    generation.value++;
  }

  // ---------------------------------------------------------------------------
  // Uploads
  // ---------------------------------------------------------------------------

  Future<UploadTask> addPhoto(
      {TaskPriority priority = TaskPriority.normal}) async {
    final n = ++_counter;
    final file = await _file('IMG_$n.jpg', (2 + n % 3) * _mb);
    return FlorevilleUploadManager.upload(
      file: file,
      url: server.url('/upload'),
      data: {'albumId': 'holiday-2026'},
      priority: priority,
      tag: 'photos',
    );
  }

  Future<UploadTask> addReceipt() async {
    final n = ++_counter;
    final file = await _file('receipt_$n.pdf', _mb ~/ 2);
    return FlorevilleUploadManager.upload(
      file: file,
      url: server.url('/upload'),
      priority: TaskPriority.critical,
    );
  }

  Future<UploadTask> addBundle() async {
    final n = ++_counter;
    final files = [
      for (var i = 1; i <= 3; i++) await _file('scan_${n}_$i.png', _mb),
    ];
    return FlorevilleUploadManager.uploadMultiple(
      files: files,
      url: server.url('/upload'),
    );
  }

  Future<UploadTask> addResumableVideo() async {
    final n = ++_counter;
    final file = await _file('clip_$n.mov', 24 * _mb);
    return FlorevilleUploadManager.upload(
      file: file,
      url: server.url('/resumable/clip_$n.mov'),
      method: 'PUT',
      protocol: UploadProtocol.resumable,
    );
  }

  Future<UploadTask> addS3Video() async {
    final n = ++_counter;
    final file = await _file('drone_4k_$n.mp4', 36 * _mb);
    return FlorevilleUploadManager.upload(
      file: file,
      url: 's3',
      protocol: UploadProtocol.s3Multipart,
      metadata: {'contentType': 'video/mp4'},
    );
  }

  Future<File> _file(String name, int size) async {
    final file = File('${workDir.path}/files/$name');
    final random = Random(name.hashCode);
    final words = Uint32List(size ~/ 4 + 1);
    for (var i = 0; i < words.length; i++) {
      words[i] = random.nextInt(1 << 32);
    }
    await file.writeAsBytes(words.buffer.asUint8List(0, size), flush: true);
    return file;
  }
}
