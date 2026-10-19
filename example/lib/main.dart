import 'dart:async';

import 'package:floreville_upload_manager/floreville_upload_manager.dart';
import 'package:floreville_upload_manager/testing.dart';
import 'package:flutter/material.dart';

import 'demo_backend.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DemoBackend.start();
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  /// Wraps the whole UI; the feature-tour test records frames from it.
  static final screenKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorSchemeSeed: const Color(0xFF3D5AFE),
          brightness: b,
          useMaterial3: true,
          cardTheme: const CardThemeData(elevation: 0),
        );
    return MaterialApp(
      title: 'Floreville Upload Manager',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: const DemoPage(),
      builder: (context, child) =>
          RepaintBoundary(key: screenKey, child: child),
    );
  }
}

class DemoPage extends StatelessWidget {
  const DemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    final backend = DemoBackend.instance;
    // Rebuild everything bound to the engine after a simulated relaunch.
    return ValueListenableBuilder<int>(
      valueListenable: backend.generation,
      builder: (context, generation, _) {
        final engine = backend.engine;
        return Scaffold(
          key: ValueKey(generation),
          appBar: AppBar(
            title: const Text('Floreville Upload Manager'),
            actions: [
              IconButton(
                key: const Key('pause-all'),
                tooltip: 'Pause all',
                icon: const Icon(Icons.pause_circle_outline),
                onPressed: engine.pauseAll,
              ),
              IconButton(
                key: const Key('resume-all'),
                tooltip: 'Resume all',
                icon: const Icon(Icons.play_circle_outline),
                onPressed: engine.resumeAll,
              ),
              IconButton(
                key: const Key('clear-finished'),
                tooltip: 'Clear finished',
                icon: const Icon(Icons.cleaning_services_outlined),
                onPressed: engine.clearFinished,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Stack(
            children: [
              Positioned.fill(child: _body(engine)),
              // Centred under the queue, clear of the side panel.
              Positioned(
                left: 0,
                right: MediaQuery.sizeOf(context).width >= 900 ? 400 : 0,
                bottom: 24,
                child: const Center(child: _Caption()),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _body(UploadEngine engine) =>
      LayoutBuilder(builder: (context, constraints) {
        final queue = _QueueColumn(engine: engine);
        if (constraints.maxWidth < 900) {
          return ListView(
            children: [
              SizedBox(height: 640, child: queue),
              const _ControlPanel(),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: queue),
            const VerticalDivider(width: 1),
            const SizedBox(width: 400, child: _ControlPanel()),
          ],
        );
      });
}

class _Caption extends StatelessWidget {
  const _Caption();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<String?>(
      valueListenable: DemoBackend.instance.caption,
      builder: (context, caption, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: caption == null
            ? const SizedBox.shrink()
            : Container(
                key: ValueKey(caption),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: scheme.inverseSurface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [
                    BoxShadow(blurRadius: 16, color: Colors.black26),
                  ],
                ),
                child: Text(
                  caption,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onInverseSurface,
                      ),
                ),
              ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Queue
// -----------------------------------------------------------------------------

class _QueueColumn extends StatelessWidget {
  const _QueueColumn({required this.engine});

  final UploadEngine engine;

  @override
  Widget build(BuildContext context) {
    final backend = DemoBackend.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryCard(engine: engine),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _AddButton('add-photo', Icons.image_outlined, 'Photo',
                  'multipart POST', backend.addPhoto),
              _AddButton('add-bundle', Icons.collections_outlined, '3 scans',
                  'one request', backend.addBundle),
              _AddButton('add-resumable', Icons.movie_outlined, 'Video 24 MB',
                  'resumable chunks', backend.addResumableVideo),
              _AddButton('add-s3', Icons.cloud_upload_outlined,
                  '4K video 36 MB', 'S3 multipart', backend.addS3Video),
              _AddButton('add-receipt', Icons.priority_high, 'Receipt',
                  'critical priority', backend.addReceipt),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          // summaryStream fires on every queue change, including removals.
          child: StreamBuilder<QueueSummary>(
            stream: engine.summaryStream,
            builder: (context, _) {
              final tasks = engine.tasks;
              if (tasks.isEmpty) {
                return const Center(
                  child:
                      Text('Add an upload to begin', key: Key('empty-queue')),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: tasks.length,
                itemBuilder: (context, i) => UploadTaskTile(
                  key: ValueKey(tasks[i].id),
                  task: tasks[i],
                  engine: engine,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton(this.id, this.icon, this.label, this.hint, this.onAdd);

  final String id;
  final IconData icon;
  final String label;
  final String hint;
  final Future<Object?> Function() onAdd;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: hint,
        child: FilledButton.tonalIcon(
          key: Key(id),
          onPressed: onAdd,
          icon: Icon(icon, size: 18),
          label: Text(label),
        ),
      );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.engine});

  final UploadEngine engine;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<QueueSummary>(
      stream: engine.summaryStream,
      initialData: engine.summary,
      builder: (context, snapshot) {
        final s = snapshot.data!;
        final parts = [
          '${s.activeTasks} uploading',
          '${s.enqueuedTasks} queued',
          if (s.waitingForRetry > 0) '${s.waitingForRetry} backing off',
          if (s.pausedTasks > 0) '${s.pausedTasks} paused',
          '${s.completedTasks} done',
          if (s.failedTasks > 0) '${s.failedTasks} failed',
        ];
        return Card(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          color: scheme.primaryContainer.withValues(alpha: 0.45),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${s.overallProgressPercent}%',
                        key: const Key('overall-percent'),
                        style: text.displaySmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(parts.join(' • '),
                          key: const Key('summary-line'),
                          style: text.bodyMedium),
                    ),
                    if (!s.isConnected)
                      Chip(
                        avatar: const Icon(Icons.wifi_off, size: 16),
                        label: const Text('Offline'),
                        backgroundColor: scheme.errorContainer,
                      )
                    else if (s.isUploading)
                      Text(s.formattedSpeed, style: text.titleMedium),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                      value: s.overallProgress, minHeight: 8),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Network, faults and server log
// -----------------------------------------------------------------------------

class _ControlPanel extends StatefulWidget {
  const _ControlPanel();

  @override
  State<_ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<_ControlPanel> {
  final _backend = DemoBackend.instance;
  final _log = <MockServerEvent>[];
  StreamSubscription<MockServerEvent>? _sub;
  String? _flash;
  Timer? _flashTimer;

  MockUploadServer get _server => _backend.server;

  @override
  void initState() {
    super.initState();
    _sub = _server.eventStream.listen((e) {
      if (!mounted) return;
      setState(() {
        _log.insert(0, e);
        if (_log.length > 60) _log.removeLast();
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }

  void _say(String message) {
    _flashTimer?.cancel();
    setState(() => _flash = message);
    _flashTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final throttle = _server.throttleBytesPerSecond;

    Widget fault(String id, IconData icon, String label, VoidCallback onTap) =>
        ActionChip(
          key: Key(id),
          avatar: Icon(icon, size: 16),
          label: Text(label),
          onPressed: onTap,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('Device', style: text.titleSmall),
        ),
        SwitchListTile(
          key: const Key('network-switch'),
          secondary:
              Icon(_backend.connectivity.online ? Icons.wifi : Icons.wifi_off),
          title: const Text('Network available'),
          subtitle: const Text('Uploads wait offline — no retries spent'),
          value: _backend.connectivity.online,
          onChanged: (v) => setState(() => _backend.connectivity.setOnline(v)),
        ),
        ListTile(
          key: const Key('kill-relaunch'),
          leading: const Icon(Icons.restart_alt),
          title: const Text('Kill & relaunch app'),
          subtitle:
              const Text('Queue restores from disk, resumes at checkpoint'),
          onTap: () async {
            await _backend.killAndRelaunch();
            _say('App relaunched — queue restored from disk');
          },
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text('Mock server  ·  ${_server.baseUrl}',
              style: text.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              fault('fault-503', Icons.error_outline, 'Next 2 → 503', () {
                _server.failNext(2, status: 503);
                _say('Next 2 upload requests will fail with 503');
              }),
              fault('fault-429', Icons.timer_outlined, '429 Retry-After 3s',
                  () {
                _server.failNext(1,
                    status: 429, retryAfter: const Duration(seconds: 3));
                _say('Next request: 429 with Retry-After: 3');
              }),
              fault('fault-drop', Icons.link_off, 'Drop connection', () {
                _server.dropNextConnection(afterBytes: 256 * 1024);
                _say('Next upload loses its connection mid-transfer');
              }),
              fault('fault-token', Icons.key_off_outlined, 'Expire token', () {
                _server.rotateToken();
                _say('Access token expired — next request gets 401');
              }),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SegmentedButton<int?>(
            key: const Key('throttle'),
            segments: const [
              ButtonSegment(value: 1024 * 1024, label: Text('1 MB/s')),
              ButtonSegment(value: 4 * 1024 * 1024, label: Text('4 MB/s')),
              ButtonSegment(value: null, label: Text('Unlimited')),
            ],
            selected: {throttle},
            onSelectionChanged: (v) =>
                setState(() => _server.throttleBytesPerSecond = v.first),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _flash == null
              ? const SizedBox(height: 12)
              : Container(
                  key: ValueKey(_flash),
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_flash!, style: text.bodySmall),
                ),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Text('HTTP log', style: text.titleSmall),
              const Spacer(),
              Text('${_server.objects.length} files stored',
                  key: const Key('stored-count'), style: text.bodySmall),
            ],
          ),
        ),
        Expanded(
          child: _log.isEmpty
              ? Center(
                  child: Text('No requests yet',
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: _log.length,
                  itemBuilder: (context, i) => _LogRow(_log[i]),
                ),
        ),
      ],
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow(this.event);

  final MockServerEvent event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = event.status;
    final color = switch (status) {
      0 => scheme.error,
      >= 200 && < 300 => Colors.green.shade600,
      308 => scheme.primary,
      >= 400 => scheme.error,
      _ => scheme.onSurfaceVariant,
    };
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'Menlo',
          fontFamilyFallback: const ['monospace'],
          fontSize: 11.5,
        );
    final path = event.path.length > 34
        ? '…${event.path.substring(event.path.length - 33)}'
        : event.path;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text(status == 0 ? '✕' : '$status',
                style:
                    mono?.copyWith(color: color, fontWeight: FontWeight.w700)),
          ),
          SizedBox(width: 36, child: Text(event.method, style: mono)),
          Expanded(
            child: Text(
              '$path${event.note != null ? '  · ${event.note}' : ''}',
              style: mono,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
