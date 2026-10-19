import 'package:flutter/material.dart';

import '../../floreville_upload_manager.dart';

/// Card showing one task with live progress and pause / resume / retry /
/// remove controls.
class UploadTaskTile extends StatefulWidget {
  const UploadTaskTile({
    super.key,
    required this.task,
    this.engine,
    this.showControls = true,
    this.onRemove,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  });

  /// Initial snapshot; the tile follows live updates for `task.id`.
  final UploadTask task;

  /// Defaults to `FlorevilleUploadManager.instance`.
  final UploadEngine? engine;
  final bool showControls;

  /// Replaces the default remove action (`deleteTask`).
  final VoidCallback? onRemove;
  final EdgeInsetsGeometry margin;

  @override
  State<UploadTaskTile> createState() => _UploadTaskTileState();
}

class _UploadTaskTileState extends State<UploadTaskTile> {
  late UploadEngine _source;
  late Stream<UploadTask> _stream;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(UploadTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id ||
        oldWidget.engine != widget.engine) {
      _subscribe();
    }
  }

  void _subscribe() {
    _source = widget.engine ?? FlorevilleUploadManager.instance;
    _stream = _source.watch(widget.task.id);
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    return StreamBuilder<UploadTask>(
      stream: _stream,
      initialData: source.getTask(widget.task.id) ?? widget.task,
      builder: (context, snapshot) {
        final current = snapshot.data ?? widget.task;
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final accent = _statusColor(current.status, scheme);

        return Card(
          margin: widget.margin,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_fileIcon(current), color: accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(current.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleSmall),
                          const SizedBox(height: 2),
                          Text(_subtitle(current),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    if (widget.showControls) ..._controls(source, current),
                  ],
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: current.status == UploadStatus.running &&
                              current.totalBytes <= 0
                          ? null
                          : current.progress,
                      minHeight: 4,
                      color: accent,
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _controls(UploadEngine source, UploadTask t) => [
        if (t.status.canPause)
          IconButton(
            icon: const Icon(Icons.pause_rounded),
            tooltip: 'Pause',
            onPressed: () => source.pause(t.id),
          ),
        if (t.status == UploadStatus.paused)
          IconButton(
            icon: const Icon(Icons.play_arrow_rounded),
            tooltip: 'Resume',
            onPressed: () => source.resume(t.id),
          ),
        if (t.status == UploadStatus.failed ||
            t.status == UploadStatus.cancelled)
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Retry',
            onPressed: () => source.retry(t.id),
          ),
        IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: t.status.isTerminal ? 'Remove' : 'Cancel and remove',
          onPressed: widget.onRemove ?? () => source.deleteTask(t.id),
        ),
      ];

  static String _subtitle(UploadTask t) {
    switch (t.status) {
      case UploadStatus.running:
        final speed =
            t.speed > 0 ? ' • ${t.formattedSpeed} • ${t.formattedEta}' : '';
        return '${t.formattedUploadedSize} of ${t.formattedTotalSize} (${t.progressPercent}%)$speed';
      case UploadStatus.enqueued:
        return t.error ?? 'Queued • ${t.formattedTotalSize}';
      case UploadStatus.failed:
        return t.error ?? 'Failed';
      case UploadStatus.paused:
        return 'Paused at ${t.progressPercent}%';
      case UploadStatus.completed:
      case UploadStatus.cancelled:
        return '${t.status.displayName} • ${t.formattedTotalSize}';
    }
  }

  static Color _statusColor(UploadStatus s, ColorScheme scheme) => switch (s) {
        UploadStatus.running => scheme.primary,
        UploadStatus.enqueued => scheme.secondary,
        UploadStatus.paused => scheme.tertiary,
        UploadStatus.completed => Colors.green.shade600,
        UploadStatus.failed => scheme.error,
        UploadStatus.cancelled => scheme.outline,
      };

  static IconData _fileIcon(UploadTask t) {
    if (t.isMultiFile) return Icons.collections_outlined;
    final name = t.fileName.toLowerCase();
    if (RegExp(r'\.(mp4|mov|m4v|webm|3gp)$').hasMatch(name)) {
      return Icons.movie_outlined;
    }
    if (RegExp(r'\.(jpe?g|png|webp|heic|gif|avif)$').hasMatch(name)) {
      return Icons.image_outlined;
    }
    if (RegExp(r'\.(mp3|m4a|aac|wav|ogg)$').hasMatch(name)) {
      return Icons.audiotrack_outlined;
    }
    if (name.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }
}
