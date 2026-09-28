// Manifest fetch over plain HTTP. One function, no clients owned:
// the caller passes its client and closes it. Non 200 is a StateError,
// bad JSON is a FormatException, both surface as screen errors.
library;

import 'package:http/http.dart' as http;

import 'update_manifest.dart';

Future<UpdateManifest> fetchUpdateManifest(
  http.Client client,
  Uri uri,
) async {
  final http.Response response = await client.get(uri);
  if (response.statusCode != 200) {
    throw StateError(
      'update check failed: HTTP ${response.statusCode}',
    );
  }
  return UpdateManifest.parse(response.body);
}
