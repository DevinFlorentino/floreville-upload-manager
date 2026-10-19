## 1.0.0

Initial release, derived from `smart_upload_manager` 1.0.1 with the tus.io
adapter removed.

- Persistent priority queue with atomic, coalesced JSON storage.
- Protocols: standard (multipart / raw PUT), resumable (`Content-Range`),
  S3 multipart via presigned parts (`S3MultipartSigner`,
  `HttpS3MultipartSigner`), simulated, custom adapters.
- Exponential backoff with jitter and `Retry-After`; backoff now actually
  gates scheduling and survives restarts.
- Resume checkpoints (offset / part ETags + file fingerprint) persisted after
  every confirmed chunk.
- `HeaderProvider` per attempt; sensitive headers never persisted; 401
  refresh-and-retry.
- Offline handling that never consumes retries.
- Aggregated, throttled notifications; permission requested on demand.
- `UploadTaskTile` and `UploadProgressBar` widgets.
- `package:floreville_upload_manager/testing.dart`: `MockUploadServer`, a
  loopback HTTP backend for every protocol with injectable faults (status
  codes, `Retry-After`, dropped connections, token expiry, expired presigned
  URLs, throttling).
- Fix: a retry timer that fired a few microseconds early (monotonic timer vs.
  wall clock) could leave a task stuck in `enqueued`; the timer now re-arms.
- End-to-end test suite against the mock server, and an integration-tested
  example app.
