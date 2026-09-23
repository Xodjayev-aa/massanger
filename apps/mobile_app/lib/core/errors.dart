import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// A user-presentable failure.
///
/// Every await in the data layer funnels through [AppException.wrap] so the UI
/// never has to know whether an error came from Postgres, PostgREST, Storage,
/// Realtime or the socket — and so server error codes keep their meaning
/// (e.g. 22023 is the schema's own `invalid_media_shape`).
class AppException implements Exception {
  const AppException(this.code, this.message, {this.retryAfterSeconds, this.cause});

  final String code;
  final String message;
  final int? retryAfterSeconds;
  final Object? cause;

  bool get isRetryable => retryAfterSeconds != null || code == 'network' || code == 'timeout' || code == '500';

  Duration? get retryDelay => retryAfterSeconds == null ? null : Duration(seconds: retryAfterSeconds!);

  factory AppException.wrap(Object error, [StackTrace? stack]) {
    if (error is AppException) return error;
    if (error is PostgrestException) {
      // `code` is nullable and often empty for a policy violation, which is exactly
      // the case where the message is the only useful thing to show.
      final code = error.code;
      return AppException(
        code == null || code.isEmpty ? 'database' : code,
        _databaseMessage(error),
        cause: error,
      );
    }
    if (error is AuthException) {
      return AppException('auth', error.message.isEmpty ? 'Sign-in failed.' : error.message, cause: error);
    }
    if (error is StorageException) {
      final statusCode = error.statusCode;
      return AppException(
        'storage',
        statusCode == '413' ? 'That file is too large for Massanger.' : error.message,
        cause: error,
      );
    }
    if (error is FunctionException) {
      return AppException(
        'function_${error.status}',
        _functionMessage(error),
        retryAfterSeconds: _retryAfter(error),
        cause: error,
      );
    }
    if (error is TimeoutException) {
      return const AppException('timeout', 'The server took too long to answer. Try again.');
    }
    if (error is SocketException || error is HttpException) {
      return const AppException('network', 'No connection to Massanger. Check the network and retry.');
    }
    return AppException('unknown', '$error', cause: error);
  }

  /// Edge functions answer with `{ok:false, error:{code, message}}`; the SDK
  /// surfaces that as a FunctionException whose details we have to read here.
  static String _functionMessage(FunctionException error) {
    // The functions return `{ok:false, error:{code, message}}`; the SDK puts that
    // body in `details`, so prefer it over the transport-level reason phrase.
    final details = error.details;
    if (details is Map) {
      final inner = details['error'];
      if (inner is Map && inner['message'] is String) return inner['message'] as String;
      if (details['message'] is String) return details['message'] as String;
    }
    final reason = (error.reasonPhrase ?? '').trim();
    return reason.isEmpty ? 'The server rejected the request (${error.status}).' : reason;
  }

  static int? _retryAfter(FunctionException error) {
    final details = error.details;
    if (details is Map) {
      final value = (details['error'] as Object?) is Map
          ? (details['error']! as Map)['retry_after_seconds']
          : details['retry_after_seconds'];
      if (value is num) return value.toInt();
    }
    return null;
  }

  static String _databaseMessage(PostgrestException error) {
    switch (error.code) {
      case '42501':
        return 'Please sign in again — your session expired.';
      case '22023':
        return 'That attachment is not in a shape Massanger accepts.';
      case '23505':
        return 'That already exists.';
      case '40001':
      case '40P01':
        return 'Too much happened at once; retrying usually works.';
      case 'PGRST301':
        return 'You do not have access to that conversation.';
      default:
        final message = error.message.trim();
        if (message.isEmpty) return 'The database rejected the request (${error.code}).';
        // Postgres messages are technical ("column x of relation y does not
        // exist") — show them verbatim only in debug builds, via the cause chain.
        return 'Something went wrong on the server. (${error.code})';
    }
  }

  @override
  String toString() => 'AppException($code): $message';
}
