import 'package:calcar/update/update_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

const String _validBody = '''
{
  "latest": {
    "versionCode": 18,
    "versionName": "0.1.0+18",
    "apkUrl": "https://github.com/Narayan201120/calcar/releases/download/mobile-18/calcar.apk",
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "previous": {
    "versionCode": 16,
    "versionName": "0.1.0+16",
    "apkUrl": "https://github.com/Narayan201120/calcar/releases/download/mobile-16/calcar.apk",
    "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
}
''';

void main() {
  group('manifest parsing', () {
    test(
      'contract: a valid manifest parses latest plus previous',
      () {
        final UpdateManifest manifest = UpdateManifest.parse(_validBody);
        expect(manifest.latest.versionCode, 18);
        expect(manifest.latest.versionName, '0.1.0+18');
        expect(
          manifest.latest.apkUrl,
          'https://github.com/Narayan201120/calcar/releases/download/mobile-18/calcar.apk',
        );
        expect(manifest.previous?.versionCode, 16);
      },
    );

    test(
      'contract: a first release without previous parses with null previous',
      () {
        const String firstBody = '''
{
  "latest": {
    "versionCode": 18,
    "versionName": "0.1.0+18",
    "apkUrl": "https://github.com/Narayan201120/calcar/releases/download/mobile-18/calcar.apk",
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
}
''';
        final UpdateManifest manifest = UpdateManifest.parse(firstBody);
        expect(manifest.latest.versionCode, 18);
        expect(manifest.previous, isNull);
      },
    );

    test(
      'contract: malformed JSON is refused, never half parsed',
      () {
        expect(() => UpdateManifest.parse('{nope'), throwsFormatException);
        expect(() => UpdateManifest.parse('[]'), throwsFormatException);
        expect(() => UpdateManifest.parse(''), throwsFormatException);
      },
    );

    test(
      'contract: missing latest is refused',
      () {
        expect(
          () => UpdateManifest.parse('{"previous": null}'),
          throwsFormatException,
        );
      },
    );

    test(
      'contract: missing required release fields are refused',
      () {
        for (final String body in <String>[
          '{"latest": {}}',
          '{"latest": {"versionCode": 18}}',
          '{"latest": {"versionCode": 18, "versionName": "x", "apkUrl": "https://example.com/a.apk"}}',
          '{"latest": {"versionCode": 18, "versionName": "x", "apkUrl": "https://example.com/a.apk", "sha256": "zzz"}}',
        ]) {
          expect(
            () => UpdateManifest.parse(body),
            throwsFormatException,
            reason: body,
          );
        }
      },
    );

    test(
      'contract: invalid versionCode is refused',
      () {
        for (final String code in <String>[
          '"18"',
          '0',
          '-3',
          '18.5',
        ]) {
          expect(
            () => UpdateManifest.parse(
              '{"latest": {"versionCode": $code, "versionName": "x", "apkUrl": "https://example.com/a.apk", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}',
            ),
            throwsFormatException,
            reason: code,
          );
        }
      },
    );

    test(
      'contract: non https apk URLs are refused',
      () {
        expect(
          () => UpdateManifest.parse(
            '{"latest": {"versionCode": 18, "versionName": "x", "apkUrl": "http://example.com/a.apk", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}',
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('version comparison', () {
    UpdateManifest manifest() => UpdateManifest.parse(_validBody);

    test(
      'contract: installed 16 against latest 18 means update available',
      () {
        expect(manifest().updateAvailable(16), isTrue);
      },
    );

    test(
      'contract: installed 18 against latest 18 means up to date',
      () {
        expect(manifest().updateAvailable(18), isFalse);
      },
    );

    test(
      'contract: gaps are fine, latest need not be current plus one',
      () {
        expect(manifest().updateAvailable(17), isTrue);
        expect(manifest().updateAvailable(15), isTrue);
      },
    );

    test(
      'contract: installed 18 with previous 16 means rollback available',
      () {
        expect(manifest().rollbackAvailable(18), isTrue);
      },
    );

    test(
      'contract: installed 16 with previous 16 means no rollback',
      () {
        expect(manifest().rollbackAvailable(16), isFalse);
      },
    );

    test(
      'contract: a manifest without previous never offers rollback',
      () {
        final UpdateManifest first = UpdateManifest(
          latest: manifest().latest,
        );
        expect(first.rollbackAvailable(18), isFalse);
        expect(first.previous, isNull);
      },
    );
  });
}
