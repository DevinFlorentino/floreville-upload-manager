/// Transport used to upload a task. Each protocol maps to a registered
/// `UploadAdapter` by [adapterId].
enum UploadProtocol {
  /// Single request: multipart/form-data (default) or a raw binary body.
  standard('standard', 'Standard HTTP'),

  /// Byte-range chunks with `Content-Range: bytes START-END/TOTAL`,
  /// resuming from the last confirmed chunk.
  resumable('resumable', 'Resumable (Content-Range)'),

  /// S3 / S3-compatible multipart upload through presigned part URLs.
  /// Requires registering an `S3MultipartUploadAdapter` with a signer.
  s3Multipart('s3_multipart', 'S3 Multipart'),

  /// Fake transfer for demos and UI tests — no network.
  simulated('simulated', 'Simulated'),

  /// Any adapter you register yourself; set `customAdapterId` on the task.
  custom('custom', 'Custom adapter');

  const UploadProtocol(this.adapterId, this.displayName);

  /// Registry key of the adapter that handles this protocol.
  final String adapterId;

  /// Human-readable label.
  final String displayName;

  /// Parses a persisted value (enum name or adapter id). Unknown values fall
  /// back to [standard].
  static UploadProtocol parse(Object? value) {
    for (final protocol in UploadProtocol.values) {
      if (protocol.name == value || protocol.adapterId == value) {
        return protocol;
      }
    }
    return UploadProtocol.standard;
  }
}
