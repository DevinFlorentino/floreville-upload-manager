import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:floreville_upload_manager/floreville_upload_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

typedef FakeBehavior = Future<UploadResponse> Function(
  UploadContext ctx,
  int attempt,
);

/// Scriptable adapter; `attempt` is 1-based.
class FakeAdapter extends UploadAdapter {
  FakeAdapter(this.behavior, {this.adapterId = 'fake'});

  final FakeBehavior behavior;
  final String adapterId;
  int attempts = 0;
  final List<Map<String, dynamic>> resumeStatesSeen = [];
  final List<Map<String, String>> headersSeen = [];
  final List<String> startedTaskIds = [];
  final List<UploadTask> cancelledTasks = [];

  @override
  String get id => adapterId;

  @override
  Future<UploadResponse> upload(UploadContext ctx) {
    attempts++;
    startedTaskIds.add(ctx.task.id);
    resumeStatesSeen.add(Map.of(ctx.resumeState));
    headersSeen.add(Map.of(ctx.task.headers));
    return behavior(ctx, attempts);
  }

  @override
  Future<void> onCancelled(UploadTask task) async => cancelledTasks.add(task);
}

Future<UploadResponse> succeed(UploadContext ctx, int _) async {
  ctx.reportProgress(100, 100);
  return const UploadResponse(statusCode: 200, data: {'ok': true});
}

/// Reports progress, checkpoints [offset], then blocks until cancelled.
Future<UploadResponse> checkpointThenHang(UploadContext ctx, int offset) async {
  ctx.reportProgress(offset, 100);
  await ctx.checkpoint({'offset': offset}, confirmedBytes: offset);
  while (!ctx.isCancelled) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  ctx.throwIfCancelled();
  throw StateError('unreachable');
}

DioException connectionError() => DioException(
      requestOptions: RequestOptions(path: '/'),
      type: DioExceptionType.connectionError,
    );

const fastRetry = RetryPolicy(
  maxRetries: 2,
  initialDelay: Duration(milliseconds: 60),
  maxDelay: Duration(milliseconds: 200),
  jitter: 0,
);

UploadEngine makeEngine({
  List<UploadAdapter> adapters = const [],
  RetryPolicy retryPolicy = fastRetry,
  ConnectivityMonitor? connectivity,
  QueueStorage? storage,
  int concurrency = 2,
  HeaderProvider? headerProvider,
}) {
  return UploadEngine(
    storage: storage ?? InMemoryQueueStorage(),
    connectivityMonitor: connectivity ?? ManualConnectivityMonitor(),
    retryPolicy: retryPolicy,
    maxConcurrentUploads: concurrency,
    headerProvider: headerProvider,
    notificationConfig: NotificationConfig.disabled,
  )..registerAdapters(adapters);
}

Future<UploadTask> enqueueFake(
  UploadEngine engine, {
  TaskPriority priority = TaskPriority.normal,
  Map<String, String> headers = const {},
  TaskSuccessCallback? onSuccess,
  TaskErrorCallback? onError,
}) =>
    engine.enqueue(
      filePaths: const [],
      url: 'https://api.test/upload',
      protocol: UploadProtocol.custom,
      customAdapterId: 'fake',
      simulatedFileSize: 100,
      priority: priority,
      headers: headers,
      onSuccess: onSuccess,
      onError: onError,
    );

/// Polls until [predicate] holds for the task.
Future<UploadTask> waitForTask(
  UploadEngine engine,
  String id,
  bool Function(UploadTask t) predicate, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final task = engine.getTask(id);
    if (task != null && predicate(task)) return task;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TestFailure(
    'Timed out waiting for ${reason ?? 'condition'} on $id '
    '(last: ${engine.getTask(id)})',
  );
}

Future<UploadTask> waitForStatus(
  UploadEngine engine,
  String id,
  UploadStatus status,
) =>
    waitForTask(engine, id, (t) => t.status == status, reason: status.name);

Future<File> tempFile(Directory dir, String name, int size) async {
  final file = File('${dir.path}/$name');
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = i % 251;
  }
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

class RecordedRequest {
  RecordedRequest(this.options, this.body);
  final RequestOptions options;
  final Uint8List body;

  String? header(String name) {
    for (final entry in options.headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) {
        return entry.value?.toString();
      }
    }
    return null;
  }
}

/// In-process HTTP stand-in for Dio.
class FakeHttp implements HttpClientAdapter {
  FakeHttp(this.handler);

  final FutureOr<ResponseBody> Function(RecordedRequest request) handler;
  final List<RecordedRequest> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final builder = BytesBuilder(copy: false);
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
    }
    final request = RecordedRequest(options, builder.takeBytes());
    requests.add(request);
    return handler(request);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(String json, int status,
        {Map<String, List<String>> headers = const {}}) =>
    ResponseBody.fromString(json, status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      ...headers,
    });

UploadContext contextFor(
  UploadTask task, {
  List<Map<String, dynamic>>? checkpoints,
  List<int>? progress,
  CancelToken? token,
}) =>
    UploadContext(
      task: task,
      cancelToken: token ?? CancelToken(),
      onProgress: (sent, _) => progress?.add(sent),
      onCheckpoint: (state, {confirmedBytes}) async =>
          checkpoints?.add(Map.of(state)),
    );
