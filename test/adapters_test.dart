import 'dart:convert';
import 'dart:io';

import 'package:floreville_upload_manager/floreville_upload_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late Directory dir;

  setUp(() async =>
      dir = await Directory.systemTemp.createTemp('floreville_adapters_'));
  tearDown(() async => dir.delete(recursive: true));

  UploadTask taskFor(
    File file, {
    String method = 'PUT',
    Map<String, dynamic> resumeState = const {},
    Map<String, String> headers = const {},
    Map<String, dynamic> metadata = const {},
    Map<String, dynamic> data = const {},
    List<String>? paths,
  }) =>
      UploadTask(
        id: 't1',
        filePaths: paths ?? [file.path],
        url: 'https://upload.test/files/1',
        method: method,
        headers: headers,
        metadata: metadata,
        data: data,
        resumeState: resumeState,
      );

  group('ResumableUploadAdapter', () {
    test('sends Content-Range chunks and checkpoints each one', () async {
      final file = await tempFile(dir, 'a.bin', 5000);
      final http = FakeHttp((r) {
        final last = r.header('content-range')!.endsWith('4999/5000');
        return last
            ? jsonBody('{"id":"f1"}', 201)
            : ResponseBody.fromString('', 308);
      });
      final adapter = ResumableUploadAdapter(
          dio: Dio()..httpClientAdapter = http, chunkSize: 2048);
      final checkpoints = <Map<String, dynamic>>[];

      final res = await adapter.upload(contextFor(
        taskFor(file, headers: {'Authorization': 'Bearer x'}),
        checkpoints: checkpoints,
      ));

      expect(http.requests.map((r) => r.header('content-range')), [
        'bytes 0-2047/5000',
        'bytes 2048-4095/5000',
        'bytes 4096-4999/5000',
      ]);
      expect(http.requests.map((r) => r.body.length), [2048, 2048, 904]);
      expect(http.requests.first.header('authorization'), 'Bearer x');
      expect(checkpoints.map((c) => c['offset']), [2048, 4096, 5000]);
      expect(res.statusCode, 201);
      expect(res.data, {'id': 'f1'});
    });

    test('resumes from a matching checkpoint', () async {
      final file = await tempFile(dir, 'b.bin', 5000);
      final fp = await FileFingerprint.of(file);
      final http = FakeHttp((r) => ResponseBody.fromString('', 200));
      final adapter = ResumableUploadAdapter(
          dio: Dio()..httpClientAdapter = http, chunkSize: 2048);

      await adapter.upload(contextFor(
          taskFor(file, resumeState: {...fp.toJson(), 'offset': 4096})));

      expect(
          http.requests.single.header('content-range'), 'bytes 4096-4999/5000');
    });

    test('discards a checkpoint when the file changed', () async {
      final file = await tempFile(dir, 'c.bin', 3000);
      final http = FakeHttp((r) => ResponseBody.fromString('', 200));
      final adapter = ResumableUploadAdapter(
          dio: Dio()..httpClientAdapter = http, chunkSize: 4096);

      await adapter.upload(contextFor(taskFor(file, resumeState: {
        'fileSize': 9999,
        'fileModifiedMs': 1,
        'offset': 2000,
      })));

      expect(http.requests.single.header('content-range'), 'bytes 0-2999/3000');
    });

    test('honours a server Range header that confirmed fewer bytes', () async {
      final file = await tempFile(dir, 'd.bin', 4000);
      var call = 0;
      final http = FakeHttp((r) {
        call++;
        if (call == 1) {
          return ResponseBody.fromString('', 308, headers: {
            'range': ['bytes=0-999']
          });
        }
        return ResponseBody.fromString('', 200);
      });
      final adapter = ResumableUploadAdapter(
          dio: Dio()..httpClientAdapter = http, chunkSize: 2000);

      await adapter.upload(contextFor(taskFor(file)));

      expect(http.requests.map((r) => r.header('content-range')), [
        'bytes 0-1999/4000',
        'bytes 1000-2999/4000',
        'bytes 3000-3999/4000',
      ]);
    });

    test('a non-2xx chunk throws a status-carrying UploadException', () async {
      final file = await tempFile(dir, 'e.bin', 100);
      final adapter = ResumableUploadAdapter(
        dio: Dio()
          ..httpClientAdapter =
              FakeHttp((_) => ResponseBody.fromString('', 503)),
      );
      await expectLater(
        adapter.upload(contextFor(taskFor(file))),
        throwsA(
            isA<UploadException>().having((e) => e.statusCode, 'status', 503)),
      );
    });
  });

  group('S3MultipartUploadAdapter', () {
    const mb = 1024 * 1024;

    test('initiate → parts with ETags → complete, checkpointing each part',
        () async {
      final file = await tempFile(dir, 'big.bin', 11 * mb);
      final signer = FakeSigner();
      final http = FakeHttp((r) {
        final n = r.options.uri.pathSegments.last;
        return ResponseBody.fromString('', 200, headers: {
          'etag': ['"etag-$n"']
        });
      });
      final adapter = S3MultipartUploadAdapter(
          signer: signer,
          dio: Dio()..httpClientAdapter = http,
          partSize: 5 * mb);
      final checkpoints = <Map<String, dynamic>>[];

      final res = await adapter.upload(contextFor(
        taskFor(file, headers: {'Authorization': 'Bearer app'}),
        checkpoints: checkpoints,
      ));

      expect(signer.initiated, 1);
      expect(http.requests.map((r) => r.body.length), [5 * mb, 5 * mb, 1 * mb]);
      // App auth goes to the signer, never to S3.
      expect(http.requests.every((r) => r.header('authorization') == null),
          isTrue);
      expect(signer.completedWith!.map((p) => p.eTag),
          ['"etag-1"', '"etag-2"', '"etag-3"']);
      expect(checkpoints.first['uploadId'], 'up-1');
      expect((checkpoints.last['parts'] as List).length, 3);
      expect(res.data, {'location': 's3://bucket/key-1'});
    });

    test('resumes with the stored session, skipping finished parts', () async {
      final file = await tempFile(dir, 'big2.bin', 11 * mb);
      final fp = await FileFingerprint.of(file);
      final signer = FakeSigner();
      final http = FakeHttp((r) => ResponseBody.fromString('', 200, headers: {
            'etag': ['"e"']
          }));
      final adapter = S3MultipartUploadAdapter(
          signer: signer,
          dio: Dio()..httpClientAdapter = http,
          partSize: 5 * mb);

      await adapter.upload(contextFor(taskFor(file, resumeState: {
        ...fp.toJson(),
        'uploadId': 'existing',
        'key': 'k',
        'partSize': 5 * mb,
        'parts': [
          {'partNumber': 1, 'eTag': '"p1"'}
        ],
      })));

      expect(signer.initiated, 0);
      expect(signer.signedParts, [2, 3]);
      expect(signer.completedWith!.first.eTag, '"p1"');
    });

    test('missing ETag is an error', () async {
      final file = await tempFile(dir, 'small.bin', 1000);
      final adapter = S3MultipartUploadAdapter(
        signer: FakeSigner(),
        dio: Dio()
          ..httpClientAdapter =
              FakeHttp((_) => ResponseBody.fromString('', 200)),
      );
      await expectLater(adapter.upload(contextFor(taskFor(file))),
          throwsA(isA<UploadException>()));
    });

    test('403 on a part is retryable (fresh presign next attempt)', () async {
      final file = await tempFile(dir, 'small2.bin', 1000);
      final adapter = S3MultipartUploadAdapter(
        signer: FakeSigner(),
        dio: Dio()
          ..httpClientAdapter =
              FakeHttp((_) => ResponseBody.fromString('', 403)),
      );
      try {
        await adapter.upload(contextFor(taskFor(file)));
        fail('expected an exception');
      } on UploadException catch (e) {
        expect(const RetryPolicy().shouldRetry(e, attemptsSoFar: 0), isTrue);
      }
    });

    test('part size grows to stay within 10,000 parts', () {
      final adapter =
          S3MultipartUploadAdapter(signer: FakeSigner(), partSize: 1);
      expect(adapter.effectivePartSize(10 * mb),
          S3MultipartUploadAdapter.minPartSize);
      const huge = 100 * 1024 * mb; // 100 GB
      expect(
          adapter.effectivePartSize(huge) * S3MultipartUploadAdapter.maxParts,
          greaterThanOrEqualTo(huge));
    });

    test('onCancelled aborts the session', () async {
      final signer = FakeSigner();
      final adapter = S3MultipartUploadAdapter(signer: signer);
      await adapter.onCancelled(UploadTask(
        id: 'x',
        filePaths: const ['/x'],
        url: '',
        resumeState: const {'uploadId': 'u', 'key': 'k'},
      ));
      expect(signer.aborted, ['u']);
    });
  });

  group('HttpS3MultipartSigner', () {
    test('speaks the documented JSON contract with app auth', () async {
      final http = FakeHttp((r) {
        final body = jsonDecode(utf8.decode(r.body)) as Map<String, dynamic>;
        switch (r.options.uri.pathSegments.last) {
          case 'initiate':
            expect(body['fileName'], 'a.mp4');
            return jsonBody('{"uploadId":"u1","key":"user/a.mp4"}', 200);
          case 'sign-part':
            expect(body['partNumber'], 2);
            return jsonBody(
                '{"url":"https://s3.test/p2","headers":{"x-amz-checksum":"c"}}',
                200);
          default:
            return jsonBody('{"ok":true}', 200);
        }
      });
      final signer = HttpS3MultipartSigner(
          baseUrl: 'https://api.test/s3/',
          dio: Dio()..httpClientAdapter = http);
      final task = UploadTask(
          id: 't',
          filePaths: const ['/a.mp4'],
          url: '',
          headers: const {'Authorization': 'Bearer z'});

      final session = await signer.initiate(task,
          fileName: 'a.mp4', contentType: 'video/mp4', fileSize: 10);
      final target =
          await signer.signPart(task, session, partNumber: 2, contentLength: 5);
      final done = await signer.complete(
          task, session, const [S3CompletedPart(partNumber: 1, eTag: '"e"')]);

      expect(session.key, 'user/a.mp4');
      expect(target.url, 'https://s3.test/p2');
      expect(target.headers, {'x-amz-checksum': 'c'});
      expect(done.data, {'ok': true});
      expect(http.requests.map((r) => r.options.uri.toString()), [
        'https://api.test/s3/initiate',
        'https://api.test/s3/sign-part',
        'https://api.test/s3/complete',
      ]);
      expect(
          http.requests.every((r) => r.header('authorization') == 'Bearer z'),
          isTrue);
    });
  });

  group('StandardUploadAdapter', () {
    test('multipart: file field, form fields, no manual content-type',
        () async {
      final file = await tempFile(dir, 'photo.jpg', 300);
      final http = FakeHttp((_) => jsonBody('{"ok":1}', 200));
      final adapter =
          StandardUploadAdapter(dio: Dio()..httpClientAdapter = http);

      await adapter.upload(contextFor(taskFor(
        file,
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        data: {
          'caption': 'hi',
          'tags': ['a', 'b'],
          'meta': {'k': 1}
        },
      )));

      final request = http.requests.single;
      final body = latin1.decode(request.body);
      expect(request.header('content-type'), startsWith('multipart/form-data'));
      expect(body, contains('name="file"; filename="photo.jpg"'));
      expect(body, contains('image/jpeg'));
      expect(body, contains('name="caption"'));
      expect('name="tags"'.allMatches(body).length, 2);
      expect(body, contains('{"k":1}'));
    });

    test('PUT defaults to a raw body with detected content-type', () async {
      final file = await tempFile(dir, 'doc.pdf', 777);
      final http = FakeHttp((_) => ResponseBody.fromString('', 200));
      final adapter =
          StandardUploadAdapter(dio: Dio()..httpClientAdapter = http);

      await adapter.upload(contextFor(taskFor(file)));

      final request = http.requests.single;
      expect(request.body.length, 777);
      expect(request.header('content-type'), 'application/pdf');
    });

    test('bundles several files under one field', () async {
      final a = await tempFile(dir, 'a.png', 10);
      final b = await tempFile(dir, 'b.png', 10);
      final http = FakeHttp((_) => ResponseBody.fromString('', 200));
      final adapter =
          StandardUploadAdapter(dio: Dio()..httpClientAdapter = http);

      await adapter.upload(contextFor(UploadTask(
        id: 'm',
        filePaths: [a.path, b.path],
        url: 'https://api.test',
        fileFieldName: 'files',
      )));

      final body = latin1.decode(http.requests.single.body);
      expect('name="files"'.allMatches(body).length, 2);
    });

    test('non-2xx becomes UploadException with the status', () async {
      final file = await tempFile(dir, 'x.txt', 5);
      final adapter = StandardUploadAdapter(
        dio: Dio()
          ..httpClientAdapter =
              FakeHttp((_) => jsonBody('{"error":"too big"}', 413)),
      );
      await expectLater(
        adapter.upload(contextFor(taskFor(file, method: 'POST'))),
        throwsA(isA<UploadException>()
            .having((e) => e.statusCode, 'status', 413)
            .having((e) => e.responseData, 'data', {'error': 'too big'})),
      );
    });
  });

  test('SimulatedUploadAdapter resumes from its checkpoint', () async {
    final adapter = SimulatedUploadAdapter(
        bytesPerSecond: 1000000, tick: const Duration(milliseconds: 1));
    final progress = <int>[];
    await adapter.upload(contextFor(
      UploadTask(
        id: 's',
        filePaths: const [],
        url: 'sim://',
        totalBytes: 5000,
        resumeState: const {'offset': 4000},
      ),
      progress: progress,
    ));
    expect(progress.first, 4000);
    expect(progress.last, 5000);
  });
}

class FakeSigner implements S3MultipartSigner {
  int initiated = 0;
  final List<int> signedParts = [];
  final List<String> aborted = [];
  List<S3CompletedPart>? completedWith;

  @override
  Future<S3MultipartSession> initiate(UploadTask task,
      {required String fileName,
      required String contentType,
      required int fileSize}) async {
    initiated++;
    return const S3MultipartSession(uploadId: 'up-1', key: 'key-1');
  }

  @override
  Future<S3PartTarget> signPart(UploadTask task, S3MultipartSession session,
      {required int partNumber, required int contentLength}) async {
    signedParts.add(partNumber);
    return S3PartTarget(url: 'https://bucket.s3.test/parts/$partNumber');
  }

  @override
  Future<UploadResponse> complete(UploadTask task, S3MultipartSession session,
      List<S3CompletedPart> parts) async {
    completedWith = parts;
    return const UploadResponse(
        statusCode: 200, data: {'location': 's3://bucket/key-1'});
  }

  @override
  Future<void> abort(UploadTask task, S3MultipartSession session) async {
    aborted.add(session.uploadId);
  }
}
