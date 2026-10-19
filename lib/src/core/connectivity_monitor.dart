import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Source of online/offline state for the engine.
abstract class ConnectivityMonitor {
  Future<bool> get isConnected;

  /// Emits only on change.
  Stream<bool> get onConnectivityChanged;

  void dispose();
}

/// `connectivity_plus`-backed monitor.
///
/// An interface being up doesn't guarantee internet (captive portals, dead
/// Wi-Fi). Set [verifyInternet] to additionally require a DNS lookup of
/// [probeHost] to succeed. Off by default — a failed request is retried
/// anyway, so this only matters if you want to avoid wasted attempts.
class DefaultConnectivityMonitor implements ConnectivityMonitor {
  DefaultConnectivityMonitor({
    Connectivity? connectivity,
    this.verifyInternet = false,
    this.probeHost = 'example.com',
    this.probeTimeout = const Duration(seconds: 3),
    this.debounce = const Duration(milliseconds: 500),
  }) : _connectivity = connectivity ?? Connectivity() {
    _subscription = _connectivity.onConnectivityChanged.listen(_onRawChange);
  }

  final Connectivity _connectivity;
  final bool verifyInternet;
  final String probeHost;
  final Duration probeTimeout;

  /// Collapses rapid flapping (e.g. Wi-Fi → mobile hand-over).
  final Duration debounce;

  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _debounceTimer;
  bool? _last;

  @override
  Future<bool> get isConnected async {
    final result = await _connectivity.checkConnectivity();
    final online = await _evaluate(result);
    _last = online;
    return online;
  }

  @override
  Stream<bool> get onConnectivityChanged => _controller.stream;

  void _onRawChange(List<ConnectivityResult> result) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () async {
      final online = await _evaluate(result);
      if (online != _last && !_controller.isClosed) {
        _last = online;
        _controller.add(online);
      }
    });
  }

  Future<bool> _evaluate(List<ConnectivityResult> result) async {
    final hasInterface = result.any((r) => r != ConnectivityResult.none);
    if (!hasInterface) return false;
    if (!verifyInternet) return true;
    try {
      final addresses =
          await InternetAddress.lookup(probeHost).timeout(probeTimeout);
      return addresses.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _subscription?.cancel();
    _controller.close();
  }
}

/// Monitor you drive by hand — for tests, demos and "Wi-Fi only" policies
/// where your app decides when uploading is allowed.
class ManualConnectivityMonitor implements ConnectivityMonitor {
  ManualConnectivityMonitor({bool online = true}) : _online = online;

  bool _online;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  bool get online => _online;

  @override
  Future<bool> get isConnected async => _online;

  @override
  Stream<bool> get onConnectivityChanged => _controller.stream;

  void setOnline(bool value) {
    if (value == _online) return;
    _online = value;
    if (!_controller.isClosed) _controller.add(value);
  }

  @override
  void dispose() => _controller.close();
}
