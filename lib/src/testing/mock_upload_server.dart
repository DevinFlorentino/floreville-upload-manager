import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';

/// A file the [MockUploadServer] received in full.
class MockStoredObject {
  MockStoredObject({
    required this.key,
    required this.bytes,
    required this.contentType,
    required this.via,
    this.fields = const {},
  }) : receivedAt = DateTime.now();

  final String key;
  final Uint8List bytes;
  final String contentType;

  /// Which endpoint stored it: `multipart`, `raw`, `resumable` or `s3`.
  final String via;

  /// Form fields that accompanied a multipart upload.
  final Map<String, String> fields;
  final DateTime receivedAt;

  int get size => bytes.length;

  Map<String, dynamic> toJson() => {
        'key': key,
        'size': size,
        'contentType': contentType,
        'via': via,
        if (fields.isNotEmpty) 'fields': fields,
      };
}

/// One handled request, for logs and assertions.
class MockServerEvent {
  MockServerEvent({
    required this.method,
    required this.path,
    required this.status,
    this.bytes = 0,
    this.note,
  }) : at = DateTime.now();

  final String method;
  final String path;
  final int status;

  /// Request body bytes received.
  final int bytes;
  final String? note;
  final DateTime at;

  @override
  String toString() =>
      '$method $path → $status${bytes > 0 ? ' ($bytes B)' : ''}'
      '${note != null ? ' · $note' : ''}';
}

class _Fault {
  _Fault(this.status, this.retryAfter);
  final int status;
  final Duration? retryAfter;
}

class _S3Session {
  _S3Session(this.key, this.contentType);
  final String key;
  final String contentType;
  final Map<int, Uint8List> parts = {};
  final Map<int, String> eTags = {};
}

/// A real HTTP server (on loopback) that speaks every protocol the upload
/// engine supports — for tests, demos and offline development.
///
/// | Endpoint | Protocol |
/// |---|---|
/// | `POST /upload` | multipart/form-data (`UploadProtocol.standard`) |
/// | `PUT /objects/<name>` | raw body, presigned-PUT style |
/// | `PUT /resumable/<id>` | `Content-Range` chunks (`UploadProtocol.resumable`) |
/// | `POST /s3/{initiate,sign-part,complete,abort}` | `HttpS3MultipartSigner` contract |
/// | `PUT /bucket/<key>?uploadId=&partNumber=` | presigned S3 part, returns `ETag` |
/// | `GET /objects` | JSON list of stored objects |
///
/// Faults are injectable at runtime: [failNext], [dropNextConnection],
/// [throttleBytesPerSecond], [requireAuth] + [rotateToken] and [presignTtl].
///
/// ```dart
/// final server = await MockUploadServer.start();
/// server.failNext(2, status: 503);
/// await engine.enqueue(filePaths: [path], url: server.url('/upload'));
/// // … later
/// expect(server.objects.single.bytes, await File(path).readAsBytes());
/// await server.close();
/// ```
class MockUploadServer {
  MockUploadServer._(this._server);

  /// Binds to the loopback interface. `port: 0` picks a free port.
  static Future<MockUploadServer> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final mock = MockUploadServer._(server);
    server.listen(mock._handle);
    return mock;
  }

  final HttpServer _server;
  final Map<String, MockStoredObject> _objects = {};
  final Map<String, BytesBuilder> _resumable = {};
  final Map<String, _S3Session> _s3 = {};
  final List<_Fault> _faults = [];
  final List<MockServerEvent> _events = [];
  final _eventController = StreamController<MockServerEvent>.broadcast();
  var _ids = 0;
  int? _dropAfterBytes;

  /// Caps how fast request bodies are read, to make progress visible.
  /// `null` = as fast as the loopback allows.
  int? throttleBytesPerSecond;

  /// When true, every endpoint except presigned bucket PUTs needs
  /// `Authorization: Bearer <validToken>`, else `401`.
  bool requireAuth = false;

  /// The bearer token currently accepted. See [rotateToken].
  String validToken = 'token-1';
  var _tokenVersion = 1;

  /// Lifetime of presigned part URLs from `/s3/sign-part`. An expired URL
  /// answers `403`, like S3.
  Duration presignTtl = const Duration(minutes: 15);

  int get port => _server.port;
  String get baseUrl => 'http://${_server.address.host}:${_server.port}';
  String url(String path) => '$baseUrl$path';

  /// Fully received files, oldest first.
  List<MockStoredObject> get objects => List.unmodifiable(_objects.values);
  MockStoredObject? object(String key) => _objects[key];

  /// Every request handled so far.
  List<MockServerEvent> get events => List.unmodifiable(_events);
  Stream<MockServerEvent> get eventStream => _eventController.stream;

  /// Open S3 multipart sessions (not yet completed or aborted).
  int get openS3Sessions => _s3.length;

  /// Bytes held for an in-progress resumable upload.
  int resumableOffset(String id) => _resumable[id]?.length ?? 0;

  /// The next [count] upload requests answer [status] (default 503). Signer
  /// and listing calls are not affected.
  void failNext(int count, {int status = 503, Duration? retryAfter}) {
    for (var i = 0; i < count; i++) {
      _faults.add(_Fault(status, retryAfter));
    }
  }

  /// The next upload request has its socket destroyed after [afterBytes]
  /// body bytes — a dropped connection mid-transfer.
  void dropNextConnection({int afterBytes = 0}) => _dropAfterBytes = afterBytes;

  /// Invalidates the current token, like a JWT expiring. Returns the new one.
  String rotateToken() => validToken = 'token-${++_tokenVersion}';

  void clearFaults() {
    _faults.clear();
    _dropAfterBytes = null;
  }

  /// Forgets stored objects, sessions and events (faults are kept).
  void reset() {
    _objects.clear();
    _resumable.clear();
    _s3.clear();
    _events.clear();
  }

  Future<void> close() async {
    await _server.close(force: true);
    await _eventController.close();
  }

  // ---------------------------------------------------------------------------
  // Routing
  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    try {
      if (method == 'GET' && path == '/objects') {
        return await _json(request, 200, {
          'objects': [for (final o in _objects.values) o.toJson()],
        });
      }
      if (method == 'POST' && path.startsWith('/s3/')) {
        if (!_authorized(request)) return await _unauthorized(request);
        return await _s3Signer(request, path.substring(4));
      }
      if (method == 'PUT' && path.startsWith('/bucket/')) {
        return await _s3Part(request, Uri.decodeComponent(path.substring(8)));
      }

      final isUpload = (method == 'POST' && path == '/upload') ||
          (method == 'PUT' &&
              (path.startsWith('/objects/') || path.startsWith('/resumable/')));
      if (!isUpload) {
        await request.drain<void>();
        return await _json(
            request, 404, {'error': 'No route for $method $path'});
      }
      if (!_authorized(request)) return await _unauthorized(request);
      if (await _injectFault(request)) return;

      if (path == '/upload') return await _multipart(request);
      if (path.startsWith('/objects/')) {
        return await _raw(request, Uri.decodeComponent(path.substring(9)));
      }
      return await _resumableChunk(request, path.substring(11));
    } on _ConnectionDropped {
      // Socket already destroyed.
    } on HttpException {
      // The client went away mid-request (pause, cancel, network loss).
    } catch (e) {
      try {
        await _json(request, 500, {'error': '$e'});
      } catch (_) {}
    }
  }

  bool _authorized(HttpRequest request) =>
      !requireAuth ||
      request.headers.value(HttpHeaders.authorizationHeader) ==
          'Bearer $validToken';

  Future<void> _unauthorized(HttpRequest request) async {
    await request.drain<void>();
    return _json(request, 401, {'error': 'Invalid or expired token'},
        note: 'auth rejected');
  }

  Future<bool> _injectFault(HttpRequest request) async {
    if (_faults.isEmpty) return false;
    final fault = _faults.removeAt(0);
    await request.drain<void>();
    if (fault.retryAfter != null) {
      request.response.headers
          .set(HttpHeaders.retryAfterHeader, fault.retryAfter!.inSeconds);
    }
    await _json(request, fault.status, {'error': 'Injected fault'},
        note: 'injected ${fault.status}');
    return true;
  }

  // ---------------------------------------------------------------------------
  // Body reading (throttle + connection drops)
  // ---------------------------------------------------------------------------

  Stream<List<int>> _body(HttpRequest request) async* {
    final dropAt = _dropAfterBytes;
    _dropAfterBytes = null;
    final watch = Stopwatch()..start();
    var received = 0;
    await for (final chunk in request) {
      if (dropAt != null && received + chunk.length > dropAt) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
        _log(request, 0, received, 'connection dropped');
        throw _ConnectionDropped();
      }
      received += chunk.length;
      final rate = throttleBytesPerSecond;
      if (rate != null && rate > 0) {
        final due = Duration(microseconds: received * 1000000 ~/ rate);
        final wait = due - watch.elapsed;
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      yield chunk;
    }
  }

  Future<Uint8List> _readAll(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _body(request)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  // ---------------------------------------------------------------------------
  // Protocols
  // ---------------------------------------------------------------------------

  Future<void> _multipart(HttpRequest request) async {
    final contentType = request.headers.contentType;
    final boundary = contentType?.parameters['boundary'];
    if (contentType?.mimeType != 'multipart/form-data' || boundary == null) {
      await request.drain<void>();
      return _json(request, 415, {'error': 'Expected multipart/form-data'});
    }

    final fields = <String, String>{};
    final files = <Map<String, dynamic>>[];
    final pending = <(String, String, String, Uint8List)>[];
    var total = 0;
    final parts = MimeMultipartTransformer(boundary).bind(_body(request));
    await for (final part in parts) {
      final disposition = HeaderValue.parse(
        part.headers['content-disposition'] ?? '',
        preserveBackslash: true,
      );
      final name = disposition.parameters['name'] ?? '';
      final filename = disposition.parameters['filename'];
      final builder = BytesBuilder(copy: false);
      await for (final chunk in part) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      total += bytes.length;
      if (filename == null) {
        fields[name] = utf8.decode(bytes);
      } else {
        pending.add((
          name,
          filename,
          part.headers['content-type'] ?? 'application/octet-stream',
          bytes,
        ));
      }
    }

    for (final (field, filename, type, bytes) in pending) {
      final key = _uniqueKey(filename);
      _objects[key] = MockStoredObject(
        key: key,
        bytes: bytes,
        contentType: type,
        via: 'multipart',
        fields: fields,
      );
      files.add({'field': field, 'key': key, 'size': bytes.length});
    }
    return _json(request, 201, {'files': files, 'fields': fields},
        bytes: total, note: '${files.length} file(s)');
  }

  Future<void> _raw(HttpRequest request, String name) async {
    final bytes = await _readAll(request);
    final key = _uniqueKey(name);
    _objects[key] = MockStoredObject(
      key: key,
      bytes: bytes,
      contentType:
          request.headers.contentType?.mimeType ?? 'application/octet-stream',
      via: 'raw',
    );
    return _json(request, 200, {'key': key, 'size': bytes.length},
        bytes: bytes.length);
  }

  static final _rangePattern = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$');
  static final _probePattern = RegExp(r'^bytes \*/(\d+)$');

  Future<void> _resumableChunk(HttpRequest request, String id) async {
    final header = request.headers.value('content-range') ?? '';
    final held = _resumable[id];

    if (_probePattern.hasMatch(header)) {
      await request.drain<void>();
      return _incomplete(request, held?.length ?? 0, note: 'offset probe');
    }

    final match = _rangePattern.firstMatch(header);
    if (match == null) {
      await request.drain<void>();
      return _json(request, 400, {'error': 'Missing Content-Range'});
    }
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    final total = int.parse(match.group(3)!);

    final buffer = start == 0 ? BytesBuilder(copy: false) : held;
    if (buffer == null || buffer.length != start) {
      // Not contiguous with what we hold: tell the client where we are.
      await request.drain<void>();
      return _incomplete(request, held?.length ?? 0,
          note: 'expected offset ${held?.length ?? 0}, got $start');
    }

    final bytes = await _readAll(request);
    if (bytes.length != end - start + 1) {
      return _json(request, 400, {'error': 'Body length mismatch'},
          bytes: bytes.length);
    }
    // Another request for this upload may have landed while we were reading
    // (e.g. a killed client's last chunk draining from the socket buffer).
    final now = _resumable[id];
    if (start > 0 && (now == null || now.length != start)) {
      return _incomplete(request, now?.length ?? 0,
          bytes: bytes.length, note: 'superseded chunk at $start');
    }
    buffer.add(bytes);
    _resumable[id] = buffer;

    if (buffer.length < total) {
      return _incomplete(request, buffer.length, bytes: bytes.length);
    }
    _resumable.remove(id);
    final key = _uniqueKey(id);
    _objects[key] = MockStoredObject(
      key: key,
      bytes: buffer.takeBytes(),
      contentType: 'application/octet-stream',
      via: 'resumable',
    );
    return _json(request, 200, {'key': key, 'size': total},
        bytes: bytes.length, note: 'complete');
  }

  Future<void> _incomplete(HttpRequest request, int held,
      {int bytes = 0, String? note}) {
    if (held > 0) request.response.headers.set('range', 'bytes=0-${held - 1}');
    request.response.statusCode = 308;
    _log(request, 308, bytes, note ?? 'have $held B');
    return request.response.close();
  }

  Future<void> _s3Signer(HttpRequest request, String action) async {
    final body = jsonDecode(utf8.decode(await _readAll(request)));
    if (body is! Map) return _json(request, 400, {'error': 'Expected JSON'});

    if (action == 'initiate') {
      final uploadId = 'mpu-${++_ids}';
      final key = 'user-1/${_uniqueKey(body['fileName'] as String? ?? 'file')}';
      _s3[uploadId] = _S3Session(
          key, body['contentType'] as String? ?? 'application/octet-stream');
      return _json(request, 200, {'uploadId': uploadId, 'key': key},
          note: 'initiate $key');
    }

    final uploadId = body['uploadId'];
    final session = _s3[uploadId];
    if (session == null || session.key != body['key']) {
      return _json(request, 404, {'error': 'NoSuchUpload'});
    }

    switch (action) {
      case 'sign-part':
        final part = body['partNumber'];
        final expires = DateTime.now().add(presignTtl).millisecondsSinceEpoch;
        final target =
            Uri.parse(url('/bucket/${Uri.encodeComponent(session.key)}'))
                .replace(queryParameters: {
          'uploadId': '$uploadId',
          'partNumber': '$part',
          'expires': '$expires',
        });
        return _json(request, 200, {'url': '$target'}, note: 'sign part $part');
      case 'complete':
        final parts = (body['parts'] as List).cast<Map>();
        final builder = BytesBuilder(copy: false);
        for (final part in parts) {
          final n = (part['partNumber'] as num).toInt();
          if (session.eTags[n] != part['eTag']) {
            return _json(request, 400, {'error': 'InvalidPart $n'});
          }
          builder.add(session.parts[n]!);
        }
        _s3.remove(uploadId);
        final bytes = builder.takeBytes();
        _objects[session.key] = MockStoredObject(
          key: session.key,
          bytes: bytes,
          contentType: session.contentType,
          via: 's3',
        );
        return _json(
            request,
            200,
            {
              'key': session.key,
              'size': bytes.length,
              'location': url('/bucket/${session.key}'),
            },
            note: 'complete ${parts.length} parts');
      case 'abort':
        _s3.remove(uploadId);
        return _json(request, 204, null, note: 'abort');
      default:
        return _json(request, 404, {'error': 'Unknown signer action'});
    }
  }

  Future<void> _s3Part(HttpRequest request, String key) async {
    final query = request.uri.queryParameters;
    final session = _s3[query['uploadId']];
    final part = int.tryParse(query['partNumber'] ?? '');
    final expires = int.tryParse(query['expires'] ?? '') ?? 0;
    if (session == null || session.key != key || part == null) {
      await request.drain<void>();
      return _json(request, 404, {'error': 'NoSuchUpload'});
    }
    if (DateTime.now().millisecondsSinceEpoch > expires) {
      await request.drain<void>();
      return _json(request, 403, {'error': 'Request has expired'},
          note: 'presigned URL expired');
    }
    if (await _injectFault(request)) return;

    final bytes = await _readAll(request);
    final eTag = '"${_fingerprint(bytes)}"';
    session.parts[part] = bytes;
    session.eTags[part] = eTag;
    request.response.headers.set('etag', eTag);
    request.response.statusCode = 200;
    _log(request, 200, bytes.length, 'part $part');
    await request.response.close();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _uniqueKey(String name) {
    if (!_objects.containsKey(name)) return name;
    return '${++_ids}-$name';
  }

  /// Cheap content hash standing in for S3's MD5 ETag (same bytes, same
  /// ETag — so a re-sent part stays consistent).
  String _fingerprint(Uint8List bytes) {
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash = ((hash ^ b) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<void> _json(HttpRequest request, int status, Object? body,
      {int bytes = 0, String? note}) {
    final response = request.response..statusCode = status;
    if (body != null) {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
    }
    _log(request, status, bytes, note);
    return response.close();
  }

  void _log(HttpRequest request, int status, int bytes, String? note) {
    final event = MockServerEvent(
      method: request.method,
      path: request.uri.path,
      status: status,
      bytes: bytes,
      note: note,
    );
    _events.add(event);
    if (!_eventController.isClosed) _eventController.add(event);
  }
}

class _ConnectionDropped implements Exception {}
