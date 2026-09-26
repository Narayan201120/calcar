/// Stable backend error codes.
///
/// Mirrors `backend/trust` (`Code*`) plus the pairing spec section 12 error
/// table. The `error` string in the JSON body is the contract; HTTP status
/// is transport only. Unknown codes are preserved verbatim, never remapped.
class ApiCodes {
  static const String pairingExpired = 'PAIRING_EXPIRED';
  static const String pairingConsumed = 'PAIRING_CONSUMED';
  static const String unknownSession = 'UNKNOWN_SESSION';
  static const String pubkeyMismatch = 'PUBKEY_MISMATCH';
  static const String revoked = 'REVOKED';
  static const String notOwner = 'NOT_OWNER';
  static const String replayedId = 'REPLAYED_ID';
  static const String badSignature = 'BAD_SIGNATURE';
  static const String invalidInput = 'INVALID_INPUT';
  static const String qrMismatch = 'QR_MISMATCH';
}

/// Transport failure for every non-2xx backend response.
///
/// Carries the stable spec `code` from the `error` JSON field so callers
/// branch on codes, not on HTTP status.
class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final bool retryable;

  const ApiException({
    required this.status,
    required this.code,
    this.message = '',
    this.retryable = false,
  });

  /// Builds the exception from a decoded error body. A missing or
  /// non-JSON body falls back to the status-derived code so the caller
  /// still gets a stable contract value.
  factory ApiException.fromBody(int status, Map<String, dynamic>? body) {
    final String code = body?['error']?.toString() ?? codeForStatus(status);
    final String message = body?['message']?.toString() ?? '';
    final bool retryable = body?['retryable'] == true;
    return ApiException(
      status: status,
      code: code.isEmpty ? codeForStatus(status) : code,
      message: message,
      retryable: retryable,
    );
  }

  /// Fallback code when the body carries no usable `error` field.
  static String codeForStatus(int status) {
    switch (status) {
      case 400:
        return ApiCodes.invalidInput;
      case 401:
        return ApiCodes.revoked;
      case 403:
        return ApiCodes.notOwner;
      case 404:
        return ApiCodes.unknownSession;
      case 409:
        return ApiCodes.replayedId;
      case 410:
        return ApiCodes.pairingExpired;
      case 422:
        return ApiCodes.pubkeyMismatch;
      default:
        return 'UNKNOWN';
    }
  }

  @override
  String toString() => 'ApiException($status $code): $message';
}
