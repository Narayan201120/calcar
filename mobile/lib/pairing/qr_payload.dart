// Pairing QR payload, exactly docs/trust/pairing-spec.md section 3:
// one URI the PC camera scans. The QR carries a session reference
// only, never trust: no signature, no key, no token, no decision.
library;

/// Builds `calcar://pair/v1?s=<session>&r=<rendezvous>&n=<nonce>&o=<owner>&v=1`.
/// Throws ArgumentError on any blank field rather than encoding a
/// half payload the PC would misread.
String buildPairingUri({
  required String sessionId,
  required String rendezvousUrl,
  required String qrNonce,
  required String ownerDeviceId,
}) {
  if (sessionId.isEmpty ||
      rendezvousUrl.isEmpty ||
      qrNonce.isEmpty ||
      ownerDeviceId.isEmpty) {
    throw ArgumentError('pairing QR fields must all be non-empty');
  }
  final Map<String, String> query = <String, String>{
    's': sessionId,
    'r': rendezvousUrl,
    'n': qrNonce,
    'o': ownerDeviceId,
    'v': '1',
  };
  final String encoded = query.entries
      .map(
        (MapEntry<String, String> field) =>
            '${field.key}=${Uri.encodeComponent(field.value)}',
      )
      .join('&');
  return 'calcar://pair/v1?$encoded';
}
