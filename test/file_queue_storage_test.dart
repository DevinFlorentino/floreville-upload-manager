import 'dart:convert';
import 'dart:io';

import 'package:floreville_upload_manager/floreville_upload_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async =>
      dir = await Directory.systemTemp.createTemp('floreville_queue_'));
  tearDown(() async => dir.delete(recursive: true));

  UploadTask make(String id, {Map<String, String> headers = const {}}) =>
      UploadTask(
        id: id,
        filePaths: ['/tmp/$id'],
        url: 'https://api.test',
        headers: headers,
        resumeState: const {'offset': 12},
      );

  Future<FileQueueStorage> open() async {
    final storage = FileQueueStorage(directoryPath: dir.path);
    await storage.init();
    return storage;
  }

  test('persists across instances and never writes secrets to disk', () async {
    final first = await open();
    await first.saveTask(make('a', headers: {
      'Authorization': 'Bearer top-secret',
      'apikey': 'supabase-anon',
      'X-Client': 'mobile',
    }));
    await first.close();

    final raw =
        await File('${dir.path}/floreville_upload_queue.json').readAsString();
    expect(raw, isNot(contains('top-secret')));
    expect(raw, isNot(contains('supabase-anon')));

    final second = await open();
    final restored = (await second.loadAll()).single;
    expect(restored.headers, {'X-Client': 'mobile'});
    expect(restored.resumeState, {'offset': 12});
  });

  test('coalesced concurrent saves all land on disk', () async {
    final storage = await open();
    await Future.wait(
        [for (var i = 0; i < 50; i++) storage.saveTask(make('t$i'))]);
    await storage.close();

    final reopened = await open();
    expect((await reopened.loadAll()).length, 50);
  });

  test('delete and clear are persisted', () async {
    final storage = await open();
    await storage.saveAll([make('a'), make('b')]);
    await storage.deleteTask('a');
    final reopened = await open();
    expect((await reopened.loadAll()).map((t) => t.id), ['b']);
    await reopened.clearAll();
    expect(await (await open()).loadAll(), isEmpty);
  });

  test('a corrupt file is moved aside and the queue starts empty', () async {
    await File('${dir.path}/floreville_upload_queue.json')
        .writeAsString('{not json');
    final storage = await open();
    expect(await storage.loadAll(), isEmpty);
    final names = dir.listSync().map((e) => e.uri.pathSegments.last).toList();
    expect(names.any((n) => n.contains('.corrupt.')), isTrue);
  });

  test('recovers from a leftover .tmp when the main file is missing', () async {
    final payload = jsonEncode({
      'version': 1,
      'tasks': [make('tmp-only').toJson()],
    });
    await File('${dir.path}/floreville_upload_queue.json.tmp')
        .writeAsString(payload);
    final storage = await open();
    expect((await storage.loadAll()).single.id, 'tmp-only');
  });

  test('persistResponses: false keeps responses out of the file', () async {
    final storage =
        FileQueueStorage(directoryPath: dir.path, persistResponses: false);
    await storage.init();
    await storage
        .saveTask(make('r').copyWith(response: {'pii': 'someone@example.com'}));
    await storage.close();
    final raw =
        await File('${dir.path}/floreville_upload_queue.json').readAsString();
    expect(raw, isNot(contains('someone@example.com')));
  });
}
