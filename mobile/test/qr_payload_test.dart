import 'package:calcar/pairing/qr_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pairing URI', () {
    test(
      'contract: builds the exact spec section 3 shape',
      () {
        expect(
          buildPairingUri(
            sessionId: '31526cb8-9666-42fb-b49b-36f4c2ca88f4',
            rendezvousUrl: 'http://100.116.16.108:8080/v1/pairing/sessions/31526cb8-9666-42fb-b49b-36f4c2ca88f4/join-request',
            qrNonce: '1NVMuSgvNiBjaFddvk8wqw',
            ownerDeviceId: 'PH-1A2B3C4D',
          ),
          'calcar://pair/v1?s=31526cb8-9666-42fb-b49b-36f4c2ca88f4'
          '&r=http%3A%2F%2F100.116.16.108%3A8080%2Fv1%2Fpairing%2Fsessions%2F31526cb8-9666-42fb-b49b-36f4c2ca88f4%2Fjoin-request'
          '&n=1NVMuSgvNiBjaFddvk8wqw&o=PH-1A2B3C4D&v=1',
        );
      },
    );

    test(
      'contract: blank fields are refused, never encoded',
      () {
        for (final Map<String, String> fields in <Map<String, String>>[
          <String, String>{
            'sessionId': '',
            'rendezvousUrl': 'https://x/y',
            'qrNonce': 'n',
            'ownerDeviceId': 'o',
          },
          <String, String>{
            'sessionId': 's',
            'rendezvousUrl': '',
            'qrNonce': 'n',
            'ownerDeviceId': 'o',
          },
          <String, String>{
            'sessionId': 's',
            'rendezvousUrl': 'https://x/y',
            'qrNonce': '',
            'ownerDeviceId': 'o',
          },
          <String, String>{
            'sessionId': 's',
            'rendezvousUrl': 'https://x/y',
            'qrNonce': 'n',
            'ownerDeviceId': '',
          },
        ]) {
          expect(
            () => buildPairingUri(
              sessionId: fields['sessionId']!,
              rendezvousUrl: fields['rendezvousUrl']!,
              qrNonce: fields['qrNonce']!,
              ownerDeviceId: fields['ownerDeviceId']!,
            ),
            throwsArgumentError,
          );
        }
      },
    );

    test(
      'contract: reserved characters are encoded, never raw',
      () {
        final String uri = buildPairingUri(
          sessionId: 's?&=%',
          rendezvousUrl: 'https://backend.test/pair',
          qrNonce: 'n',
          ownerDeviceId: 'o',
        );
        expect(uri.startsWith('calcar://pair/v1?'), isTrue);
        expect(uri, contains('s=s%3F%26%3D%25'));
        expect(uri, contains('&v=1'));
      },
    );
  });
}
