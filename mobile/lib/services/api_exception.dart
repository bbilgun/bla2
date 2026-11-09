// The error type every API call throws.
import '../app/strings.dart';

/// A failed API call. The server sends `{ error: { code, message, details } }`, and [ApiClient.mapError]
/// turns that, or a network failure, into one of these.
class ApiException implements Exception {
  ApiException({
    required this.code,
    required this.message,
    this.status,
    this.fieldErrors = const {},
    this.details = const [],
    this.serverMessage,
  });

  /// The server's error code, such as `EXPENSE_NOT_FOUND`, or `NETWORK` when no answer arrived.
  final String code;

  /// Mongolian text to show the user, from [S.apiError].
  final String message;

  /// The server's own English message, kept for debugging and never shown.
  final String? serverMessage;

  /// HTTP status, or null when the request never got an answer.
  final int? status;

  /// Server validation errors keyed by field path, such as "amountCents" or "split.shares.0.userId".
  final Map<String, String> fieldErrors;

  /// The server's `details` as sent. With `BALANCES_NOT_ZERO` it lists the unsettled groups.
  final List<Object?> details;

  /// Whether the request may or may not have reached the server, as with a timeout or no connection.
  /// This is the one case where retrying a write with the same Idempotency-Key is the right move.
  bool get isNetwork => code == 'NETWORK';

  @override
  String toString() => message;
}

/// The group doesn't exist or the caller isn't in it. The server deliberately doesn't say which.
class GroupNotFoundException extends ApiException {
  GroupNotFoundException({super.serverMessage})
    : super(code: 'GROUP_NOT_FOUND', message: S.apiError('GROUP_NOT_FOUND'), status: 404);
}
