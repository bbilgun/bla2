import '../app/strings.dart';

/// Every API failure, mapped from the server's `{ error: { code, message, details } }`.
/// [message] is always Mongolian text for the person ([S.apiError]); [serverMessage] is the
/// server's English wording, kept for debugging.
class ApiException implements Exception {
  ApiException({
    required this.code,
    required this.message,
    this.status,
    this.fieldErrors = const {},
    this.details = const [],
    this.serverMessage,
  });

  final String code;
  final String message;
  final String? serverMessage;
  final int? status;

  /// Server validation errors keyed by field path ("amountCents", "split.shares.0.userId").
  final Map<String, String> fieldErrors;

  /// The server's `details` as sent, e.g. `[{groupId, name}]` with BALANCES_NOT_ZERO.
  final List<Object?> details;

  /// True when the request may or may not have reached the server (timeout, no connection).
  /// Retrying a money write with the same Idempotency-Key is safe in exactly this case.
  bool get isNetwork => code == 'NETWORK';

  @override
  String toString() => message;
}

/// You are not in this group (or it doesn't exist). The server doesn't say which, on purpose.
class GroupNotFoundException extends ApiException {
  GroupNotFoundException({super.serverMessage})
    : super(code: 'GROUP_NOT_FOUND', message: S.apiError('GROUP_NOT_FOUND'), status: 404);
}
