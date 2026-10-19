# floreville_upload_manager example

The app from the package's demo video. It starts `MockUploadServer` inside
the app, generates real files, and uploads them over every protocol:
multipart, a 3-file bundle, resumable `Content-Range` chunks and S3
multipart. The side panel injects failures (503s, `Retry-After`, dropped
connections, an expiring token, throttling, going offline, killing and
relaunching the app) and shows the live HTTP log.

```bash
flutter create . --platforms=macos   # or android, ios, linux, windows
flutter run
```

The scripted feature tour doubles as an end-to-end UI test:

```bash
flutter test integration_test/feature_tour_test.dart -d macos
```

To re-record the demo video, start `python3 tool/record_relay.py demo.mp4`
(needs ffmpeg) and add `--dart-define=RECORD_PORT=9777` to the command above.

The interesting code is in [`lib/demo_backend.dart`](lib/demo_backend.dart):
engine setup, a token-refreshing `headerProvider`, and one method per upload
style.
