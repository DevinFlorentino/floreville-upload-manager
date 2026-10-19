import 'package:flutter/material.dart';

import '../../floreville_upload_manager.dart';

/// Self-updating progress bar for one task.
class UploadProgressBar extends StatefulWidget {
  const UploadProgressBar({
    super.key,
    required this.taskId,
    this.engine,
    this.height = 6,
    this.color,
    this.backgroundColor,
    this.showMetrics = true,
  });

  final String taskId;

  /// Defaults to `FlorevilleUploadManager.instance`.
  final UploadEngine? engine;
  final double height;
  final Color? color;
  final Color? backgroundColor;

  /// Percentage, speed and ETA under the bar while running.
  final bool showMetrics;

  @override
  State<UploadProgressBar> createState() => _UploadProgressBarState();
}

class _UploadProgressBarState extends State<UploadProgressBar> {
  late UploadEngine _source;
  late Stream<UploadTask> _stream;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(UploadProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId != widget.taskId ||
        oldWidget.engine != widget.engine) {
      _subscribe();
    }
  }

  void _subscribe() {
    _source = widget.engine ?? FlorevilleUploadManager.instance;
    _stream = _source.watch(widget.taskId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = widget.height;
    return StreamBuilder<UploadTask>(
      stream: _stream,
      initialData: _source.getTask(widget.taskId),
      builder: (context, snapshot) {
        final task = snapshot.data;
        if (task == null) return const SizedBox.shrink();
        final running = task.status == UploadStatus.running;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: 'Upload progress',
              value: '${task.progressPercent}%',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(height / 2),
                child: LinearProgressIndicator(
                  value: task.totalBytes > 0 || task.status.isTerminal
                      ? task.progress
                      : (running ? null : 0.0),
                  minHeight: height,
                  color: widget.color ?? theme.colorScheme.primary,
                  backgroundColor: widget.backgroundColor ??
                      theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            if (widget.showMetrics && running) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Text('${task.progressPercent}%',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (task.speed > 0)
                    Text('${task.formattedSpeed} • ${task.formattedEta} left',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
