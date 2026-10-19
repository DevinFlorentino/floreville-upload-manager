import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../models/upload_exception.dart';

/// Decides whether a failed attempt is retried, and after how long.
///
/// Delay for attempt `n` (1-based) is
/// `initialDelay * multiplier^(n-1)`, capped at [maxDelay], then spread by
/// ±[jitter] so a fleet of devices doesn't retry in lock-step. A server
/// `Retry-After` header always wins (still capped at [maxDelay]).
class RetryPolicy {
  const RetryPolicy({
    this.maxRetries = 5,
    this.initialDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(minutes: 5),
    this.multiplier = 2.0,
    this.jitter = 0.2,
    this.retryableStatusCodes = const {408, 425, 429, 500, 502, 503, 504},
    this.retryOnUnauthorized = true,
    this.shouldRetryOverride,
  })  : assert(maxRetries >= 0),
        assert(multiplier >= 1),
        assert(jitter >= 0 && jitter < 1);

  /// Never retry automatically.
  static const RetryPolicy none = RetryPolicy(maxRetries: 0);

  /// Automatic retries after the first attempt.
  final int maxRetries;
  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;

  /// Fraction of random spread, e.g. 0.2 = ±20 %. 0 disables jitter.
  final double jitter;

  /// HTTP statuses considered transient. Any other 5xx except 501 is also
  /// treated as transient.
  final Set<int> retryableStatusCodes;

  /// Retry a 401 when a `HeaderProvider` is configured — it gets a chance to
  /// supply a refreshed token on the next attempt (e.g. an expired JWT).
  final bool retryOnUnauthorized;

  /// Full override of the retry decision. Return null to fall back to the
  /// built-in rules. `attempt` is the number of retries already consumed.
  final bool? Function(Object error, int attempt)? shouldRetryOverride;

  /// Delay before retry number [attempt] (1-based).
  Duration delayFor(int attempt, {Object? error, Random? random}) {
    final serverHint = _retryAfterOf(error);
    if (serverHint != null) {
      return serverHint > maxDelay ? maxDelay : serverHint;
    }

    final n = attempt < 1 ? 1 : attempt;
    var millis =
        initialDelay.inMilliseconds * pow(multiplier, n - 1).toDouble();
    millis = min(millis, maxDelay.inMilliseconds.toDouble());
    if (jitter > 0) {
      final factor =
          1 - jitter + (random ?? Random()).nextDouble() * 2 * jitter;
      millis = min(millis * factor, maxDelay.inMilliseconds.toDouble());
    }
    return Duration(milliseconds: max(0, millis.round()));
  }

  /// Whether to retry after [error], given [attemptsSoFar] retries used.
  bool shouldRetry(
    Object error, {
    required int attemptsSoFar,
    int? maxRetriesOverride,
    bool canRefreshAuth = false,
  }) {
    if (attemptsSoFar >= (maxRetriesOverride ?? maxRetries)) return false;

    final override = shouldRetryOverride?.call(error, attemptsSoFar);
    if (override != null) return override;

    if (error is UploadException) {
      if (error.retryableOverride != null) return error.retryableOverride!;
      final status = error.statusCode;
      if (status != null) return _isRetryableStatus(status, canRefreshAuth);
      return error.retryable;
    }

    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return true;
        case DioExceptionType.badResponse:
          final status = error.response?.statusCode;
          return status == null || _isRetryableStatus(status, canRefreshAuth);
        case DioExceptionType.cancel:
        case DioExceptionType.badCertificate:
          return false;
        case DioExceptionType.unknown:
          final inner = error.error;
          return inner is SocketException ||
              inner is HttpException ||
              inner is TimeoutException;
        // ignore: unreachable_switch_default
        default:
          // Newer dio versions add timeout variants (e.g. transformTimeout).
          return error.type.name.toLowerCase().contains('timeout');
      }
    }

    // Local file problems (missing/unreadable) won't fix themselves.
    if (error is FileSystemException) return false;

    return error is SocketException ||
        error is HttpException ||
        error is TimeoutException;
  }

  bool _isRetryableStatus(int status, bool canRefreshAuth) {
    if (status == 401) return retryOnUnauthorized && canRefreshAuth;
    if (retryableStatusCodes.contains(status)) return true;
    return status >= 500 && status != 501;
  }

  static Duration? _retryAfterOf(Object? error) {
    if (error is UploadException) return error.retryAfter;
    if (error is DioException) {
      return UploadException.parseRetryAfter(
        error.response?.headers.value('retry-after'),
      );
    }
    return null;
  }
}
