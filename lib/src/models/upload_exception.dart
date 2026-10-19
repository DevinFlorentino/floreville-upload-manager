/// Error raised by adapters and the engine.
///
/// [retryable] tells the default `RetryPolicy` whether trying again can help.
/// When [statusCode] is set, the policy's status-code rules decide instead
/// (unless [retryableOverride] was given).
class UploadException implements Exception {
  const UploadException(
    this.message, {
    this.statusCode,
    this.responseData,
    this.retryable = false,
    this.retryableOverride,
    this.retryAfter,
    this.cause,
  });

  /// Non-2xx HTTP response. Parses `Retry-After` (seconds or HTTP date).
  factory UploadException.http(
    int statusCode,
    Object? responseData, {
    Map<String, List<String>> headers = const {},
    bool? retryableOverride,
  }) {
    return UploadException(
      _serverMessage(responseData) ?? 'Request failed',
      statusCode: statusCode,
      responseData: responseData,
      retryableOverride: retryableOverride,
      retryAfter: parseRetryAfter(_header(headers, 'retry-after')),
    );
  }

  final String message;
  final int? statusCode;
  final Object? responseData;

  /// Used when there is no [statusCode].
  final bool retryable;

  /// Forces the retry decision regardless of [statusCode].
  final bool? retryableOverride;

  /// Server-requested delay before retrying.
  final Duration? retryAfter;

  final Object? cause;

  /// Picks a human message out of common error bodies:
  /// `{"message": …}`, `{"error": …}`, `{"error": {"message": …}}`, or a
  /// short plain-text body.
  static String? _serverMessage(Object? data) {
    if (data is Map) {
      for (final key in const [
        'message',
        'error_description',
        'error',
        'msg'
      ]) {
        final value = data[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
        if (value is Map && value['message'] is String) {
          return (value['message'] as String).trim();
        }
      }
      return null;
    }
    if (data is String) {
      final text = data.trim();
      if (text.isNotEmpty && text.length <= 200 && !text.startsWith('<')) {
        return text;
      }
    }
    return null;
  }

  static String? _header(Map<String, List<String>> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name && entry.value.isNotEmpty) {
        return entry.value.first;
      }
    }
    return null;
  }

  /// Parses a `Retry-After` header value.
  static Duration? parseRetryAfter(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return Duration(seconds: seconds < 0 ? 0 : seconds);
    try {
      final date = HttpDateParser.parse(value.trim());
      final diff = date.difference(DateTime.now().toUtc());
      return diff.isNegative ? Duration.zero : diff;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => statusCode == null
      ? 'UploadException: $message'
      : 'UploadException($statusCode): $message';
}

/// Minimal RFC 7231 IMF-fixdate parser ("Wed, 21 Oct 2015 07:28:00 GMT"),
/// avoiding a dart:io dependency in the model layer.
class HttpDateParser {
  static const _months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static DateTime parse(String value) {
    final match = RegExp(
      r'^\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
    ).firstMatch(value);
    if (match == null) throw FormatException('Invalid HTTP date', value);
    final month = _months[match.group(2)!.toLowerCase()];
    if (month == null) throw FormatException('Invalid month', value);
    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }
}
