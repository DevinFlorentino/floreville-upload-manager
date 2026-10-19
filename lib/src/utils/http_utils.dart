import 'dart:io';

import 'package:path/path.dart' as p;

const Map<String, String> _mimeByExtension = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.heic': 'image/heic',
  '.heif': 'image/heif',
  '.avif': 'image/avif',
  '.svg': 'image/svg+xml',
  '.mp4': 'video/mp4',
  '.m4v': 'video/x-m4v',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
  '.3gp': 'video/3gpp',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.wav': 'audio/wav',
  '.ogg': 'audio/ogg',
  '.pdf': 'application/pdf',
  '.json': 'application/json',
  '.txt': 'text/plain',
  '.csv': 'text/csv',
  '.zip': 'application/zip',
  '.doc': 'application/msword',
  '.docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};

/// Best-effort MIME type from a file extension.
String mimeTypeFor(String path,
        {String fallback = 'application/octet-stream'}) =>
    _mimeByExtension[p.extension(path).toLowerCase()] ?? fallback;

/// Returns [base] with [overrides] applied, replacing keys case-insensitively
/// so you never send both `content-type` and `Content-Type`.
Map<String, dynamic> mergeHeaders(
  Map<String, String> base,
  Map<String, Object> overrides,
) {
  final result = <String, dynamic>{};
  final overrideKeys = overrides.keys.map((k) => k.toLowerCase()).toSet();
  for (final entry in base.entries) {
    if (!overrideKeys.contains(entry.key.toLowerCase())) {
      result[entry.key] = entry.value;
    }
  }
  result.addAll(overrides);
  return result;
}

/// Removes every key matching [name] case-insensitively.
Map<String, dynamic> withoutHeader(Map<String, dynamic> headers, String name) {
  final lower = name.toLowerCase();
  return Map<String, dynamic>.of(headers)
    ..removeWhere((key, _) => key.toLowerCase() == lower);
}

bool hasHeader(Map<String, Object?> headers, String name) {
  final lower = name.toLowerCase();
  return headers.keys.any((k) => k.toLowerCase() == lower);
}

/// Size + modification time of a file — used to detect that the file
/// behind a resume checkpoint has changed (then the checkpoint is discarded).
class FileFingerprint {
  const FileFingerprint({required this.size, required this.modifiedMs});

  final int size;
  final int modifiedMs;

  static Future<FileFingerprint> of(File file) async {
    final stat = await file.stat();
    return FileFingerprint(
      size: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  bool matches(Map<String, dynamic> state) =>
      (state['fileSize'] as num?)?.toInt() == size &&
      (state['fileModifiedMs'] as num?)?.toInt() == modifiedMs;

  Map<String, dynamic> toJson() =>
      {'fileSize': size, 'fileModifiedMs': modifiedMs};
}
