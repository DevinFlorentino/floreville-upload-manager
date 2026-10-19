import 'dart:io';
import 'dart:math';

import 'package:floreville_upload_manager/floreville_upload_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

DioException dio(DioExceptionType type,
    {int? status, Map<String, List<String>>? headers}) {
  final options = RequestOptions(path: '/');
  return DioException(
    requestOptions: options,
    type: type,
    response: status == null
        ? null
        : Response<dynamic>(
            requestOptions: options,
            statusCode: status,
            headers: Headers.fromMap(headers ?? {}),
          ),
  );
}

void main() {
  const policy = RetryPolicy(
    maxRetries: 5,
    initialDelay: Duration(seconds: 2),
    maxDelay: Duration(seconds: 30),
    jitter: 0,
  );

  group('delayFor', () {
    test('grows exponentially and caps at maxDelay', () {
      expect(policy.delayFor(1), const Duration(seconds: 2));
      expect(policy.delayFor(2), const Duration(seconds: 4));
      expect(policy.delayFor(3), const Duration(seconds: 8));
      expect(policy.delayFor(10), const Duration(seconds: 30));
    });

    test('jitter stays within ±20%', () {
      const jittery =
          RetryPolicy(initialDelay: Duration(seconds: 10), jitter: 0.2);
      final random = Random(42);
      for (var i = 0; i < 200; i++) {
        final ms = jittery.delayFor(1, random: random).inMilliseconds;
        expect(ms, inInclusiveRange(8000, 12000));
      }
    });

    test('honours Retry-After seconds, capped at maxDelay', () {
      expect(
        policy.delayFor(1,
            error: UploadException.http(429, null, headers: {
              'Retry-After': ['7']
            })),
        const Duration(seconds: 7),
      );
      expect(
        policy.delayFor(1,
            error: UploadException.http(503, null, headers: {
              'retry-after': ['3600']
            })),
        const Duration(seconds: 30),
      );
    });

    test('parses an HTTP-date Retry-After', () {
      final future = DateTime.now().toUtc().add(const Duration(seconds: 20));
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ];
      String two(int v) => v.toString().padLeft(2, '0');
      final header = '${days[future.weekday - 1]}, ${two(future.day)} '
          '${months[future.month - 1]} ${future.year} '
          '${two(future.hour)}:${two(future.minute)}:${two(future.second)} GMT';
      final parsed = UploadException.parseRetryAfter(header)!;
      expect(parsed.inSeconds, inInclusiveRange(18, 20));
    });
  });

  group('shouldRetry', () {
    bool retry(Object e, {int attempts = 0, bool auth = false}) =>
        policy.shouldRetry(e, attemptsSoFar: attempts, canRefreshAuth: auth);

    test('network failures are transient', () {
      expect(retry(dio(DioExceptionType.connectionError)), isTrue);
      expect(retry(dio(DioExceptionType.sendTimeout)), isTrue);
      expect(retry(dio(DioExceptionType.connectionTimeout)), isTrue);
      expect(retry(const SocketException('down')), isTrue);
    });

    test('status code rules', () {
      for (final code in [408, 429, 500, 502, 503, 504, 599]) {
        expect(retry(UploadException.http(code, null)), isTrue,
            reason: '$code');
      }
      for (final code in [400, 403, 404, 413, 422, 501]) {
        expect(retry(UploadException.http(code, null)), isFalse,
            reason: '$code');
      }
      expect(retry(dio(DioExceptionType.badResponse, status: 503)), isTrue);
      expect(retry(dio(DioExceptionType.badResponse, status: 404)), isFalse);
    });

    test('401 is retried only when auth can be refreshed', () {
      expect(retry(UploadException.http(401, null)), isFalse);
      expect(retry(UploadException.http(401, null), auth: true), isTrue);
      const noAuthRetry = RetryPolicy(retryOnUnauthorized: false);
      expect(
        noAuthRetry.shouldRetry(UploadException.http(401, null),
            attemptsSoFar: 0, canRefreshAuth: true),
        isFalse,
      );
    });

    test('cancellation, certificates and missing files are final', () {
      expect(retry(dio(DioExceptionType.cancel)), isFalse);
      expect(retry(dio(DioExceptionType.badCertificate)), isFalse);
      expect(retry(const FileSystemException('gone', '/x')), isFalse);
      expect(retry(const UploadException('nope')), isFalse);
      expect(retry(const UploadException('flaky', retryable: true)), isTrue);
    });

    test('retryableOverride wins over status rules', () {
      expect(retry(UploadException.http(403, null, retryableOverride: true)),
          isTrue);
    });

    test('stops at maxRetries and per-task override', () {
      final e = dio(DioExceptionType.connectionError);
      expect(retry(e, attempts: 4), isTrue);
      expect(retry(e, attempts: 5), isFalse);
      expect(policy.shouldRetry(e, attemptsSoFar: 1, maxRetriesOverride: 1),
          isFalse);
      expect(RetryPolicy.none.shouldRetry(e, attemptsSoFar: 0), isFalse);
    });

    test('custom override; null falls through', () {
      final custom = RetryPolicy(
        shouldRetryOverride: (e, _) => e is StateError ? true : null,
      );
      expect(custom.shouldRetry(StateError('x'), attemptsSoFar: 0), isTrue);
      expect(
          custom.shouldRetry(UploadException.http(400, null), attemptsSoFar: 0),
          isFalse);
    });
  });
}
