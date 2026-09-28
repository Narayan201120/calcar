// Update manifest: the machine-readable record of which APKs the
// release process published. `latest` is the newest successful
// mobile-apk run, `previous` is the successful run before it, never
// current minus one, since failed runs leave gaps like 16 then 18.
// Parsing is strict: anything missing or malformed is a FormatException
// and the caller shows an error instead of downloading.
library;

import 'dart:convert';

/// One published APK. versionCode is the mobile-apk run number and the
/// only field ever compared. versionName is display text.
class UpdateRelease {
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String sha256;

  const UpdateRelease({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    required this.sha256,
  });

  factory UpdateRelease.fromJson(Map<String, dynamic> json, String which) {
    final Object? code = json['versionCode'];
    if (code is! int || code <= 0) {
      throw FormatException('update manifest $which has no valid versionCode');
    }
    final String name = json['versionName']?.toString() ?? '';
    final String url = json['apkUrl']?.toString() ?? '';
    final String sha = json['sha256']?.toString() ?? '';
    if (name.isEmpty || url.isEmpty || sha.isEmpty) {
      throw FormatException('update manifest $which is missing fields');
    }
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.scheme != 'https') {
      throw FormatException('update manifest $which apkUrl is not https');
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha)) {
      throw FormatException('update manifest $which sha256 is not hex64');
    }
    return UpdateRelease(
      versionCode: code,
      versionName: name,
      apkUrl: url,
      sha256: sha.toLowerCase(),
    );
  }
}

/// Latest plus at most one previous release. A first release has no
/// previous, which is null rather than a guess.
class UpdateManifest {
  final UpdateRelease latest;
  final UpdateRelease? previous;

  const UpdateManifest({
    required this.latest,
    this.previous,
  });

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final Object? rawLatest = json['latest'];
    if (rawLatest is! Map<String, dynamic>) {
      throw const FormatException('update manifest is missing latest');
    }
    UpdateRelease? previous;
    final Object? rawPrevious = json['previous'];
    if (rawPrevious != null) {
      if (rawPrevious is! Map<String, dynamic>) {
        throw const FormatException('update manifest previous is not an object');
      }
      previous = UpdateRelease.fromJson(rawPrevious, 'previous');
    }
    return UpdateManifest(
      latest: UpdateRelease.fromJson(rawLatest, 'latest'),
      previous: previous,
    );
  }

  /// Parses the manifest body. Throws FormatException on malformed JSON
  /// or missing fields, StateError never: parsing cannot fail that way.
  static UpdateManifest parse(String body) {
    final Object decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('update manifest is not a JSON object');
    }
    return UpdateManifest.fromJson(decoded);
  }

  /// Version codes only, never version strings. Gaps are normal: 16
  /// against 18 is an update even though 17 never shipped.
  bool updateAvailable(int installedCode) {
    return latest.versionCode > installedCode;
  }

  /// Rollback needs a previous release older than what runs now.
  bool rollbackAvailable(int installedCode) {
    final UpdateRelease? prev = previous;
    return prev != null && prev.versionCode < installedCode;
  }
}
