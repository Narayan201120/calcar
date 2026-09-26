// HTTP snapshot source contract tests. Canned JSON only, no network: the
// backend half rides a MockClient on CalcarApiClient and the agent half
// rides a MockClient on AgentChannelClient, so both transports are
// proven without a socket. Each test names the contract it guards.
//
// Failure modes first: a device with no presence record, an unknown
// Owner role, a token change between refreshes, malformed rows in an
// agent body, and agent or backend failures that must surface instead of
// reading as an empty snapshot.
import 'dart:convert';

import 'package:calcar/api/agent_channel.dart';
import 'package:calcar/api/api_error.dart';
import 'package:calcar/api/client.dart';
import 'package:calcar/api/models.dart';
import 'package:calcar/state/http_snapshot_source.dart';
import 'package:calcar/state/models.dart';
import 'package:calcar/state/snapshot_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Canned JSON body, the shape every reply in this file takes.
http.Response _json(Object body, {int status = 200}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: <String, String>{'Content-Type': 'application/json'},
  );
}

/// One device row as the backend writes it.
Map<String, dynamic> _device(
  String deviceId,
  String role, {
  String displayName = '',
  bool revoked = false,
  String authorizedBy = '',
}) {
  return <String, dynamic>{
    'device_id': deviceId,
    'role': role,
    'display_name': displayName,
    'pubkey_b64': 'pk-$deviceId',
    'fingerprint': 'A91C 7D24',
    'revoked': revoked,
    'authorized_by': authorizedBy,
  };
}

/// Presence record as the backend writes it, keyed by the device the
/// lookup addressed.
Map<String, dynamic> _presence(
  String deviceId, {
  required bool online,
  int lastSeenMillis = 1700000000000,
}) {
  return <String, dynamic>{
    'device_id': deviceId,
    'online': online,
    'last_seen_millis': lastSeenMillis,
  };
}

/// Backend mock for the only two endpoints a device snapshot uses. A
/// device with no [presence] record answers the backend's real 404
/// NO_PRESENCE. Requests land in [seen] so a test can pin the wire cost
/// of a refresh. Any other path answers 404 as well, so a routing slip
/// in this fixture shows up as a wrong assertion instead of a hang.
MockClient backendMock(
  List<Map<String, dynamic>> devices, {
  Map<String, Map<String, dynamic>> presence =
      const <String, Map<String, dynamic>>{},
  List<http.Request>? seen,
}) {
  return MockClient((http.Request request) async {
    seen?.add(request);
    if (request.url.path == '/v1/devices') {
      return _json(<String, dynamic>{'devices': devices});
    }
    final RegExpMatch? match =
        RegExp(r'^/v1/computers/([^/]+)/presence$').firstMatch(request.url.path);
    final Map<String, dynamic>? record =
        match == null ? null : presence[match.group(1)!];
    if (record == null) {
      return _json(
        <String, dynamic>{
          'error': 'NO_PRESENCE',
          'message': 'no presence recorded',
          'retryable': false,
        },
        status: 404,
      );
    }
    return _json(record);
  });
}

/// Agent mock answering one canned body for every agent path. Requests
/// land in [seen], so a test can pin which computer and workflow the
/// source addressed and under which bearer token.
MockClient agentMock(
  Object body, {
  List<http.Request>? seen,
  int status = 200,
}) {
  return MockClient((http.Request request) async {
    seen?.add(request);
    return _json(body, status: status);
  });
}

/// Source under test. Only the transport a test exercises needs a canned
/// client; the other side answers an empty body.
HttpSnapshotSource _source({
  MockClient? backend,
  MockClient? agent,
  String token = 'tok-123',
}) {
  return HttpSnapshotSource(
    api: CalcarApiClient(
      baseUrl: 'https://backend.test',
      token: token,
      httpClient: backend ??
          MockClient((http.Request request) async {
            return _json(<String, dynamic>{});
          }),
    ),
    agent: AgentChannelClient(
      baseUrl: 'https://agent.test',
      token: token,
      httpClient: agent ??
          MockClient((http.Request request) async {
            return _json(<String, dynamic>{});
          }),
    ),
  );
}

void main() {
  group('device snapshot from the backend', () {
    test('contract: devices keep the backend wire fields verbatim', () async {
      final HttpSnapshotSource source = _source(
        backend: backendMock(<Map<String, dynamic>>[
          _device('PH-owner', 'owner_phone', displayName: 'Owner Pixel'),
          _device(
            'PC-1',
            'computer',
            displayName: 'WIN-PC',
            revoked: true,
            authorizedBy: 'PH-owner',
          ),
        ]),
      );

      final List<Device> devices = await source.fetchDevices();

      expect(
        devices.map((Device device) => device.deviceId).toList(),
        <String>['PH-owner', 'PC-1'],
      );
      expect(devices.first.role, 'owner_phone');
      expect(devices.first.displayName, 'Owner Pixel');
      // A loose truthiness read on revoked would mark a live owner
      // revoked and drop its revoke button.
      expect(devices.first.revoked, isFalse);
      expect(devices.last.displayName, 'WIN-PC');
      expect(devices.last.revoked, isTrue);
      expect(devices.last.authorizedBy, 'PH-owner');
    });

    test('contract: presence is keyed by device id across the fan-out', () async {
      final HttpSnapshotSource source = _source(
        backend: backendMock(
          <Map<String, dynamic>>[
            _device('PH-owner', 'owner_phone'),
            _device('PC-1', 'computer'),
          ],
          presence: <String, Map<String, dynamic>>{
            'PH-owner': _presence('PH-owner', online: true),
            'PC-1': _presence(
              'PC-1',
              online: false,
              lastSeenMillis: 1699999999000,
            ),
          },
        ),
      );

      final Map<String, Presence> byId = await source.fetchPresence();

      expect(byId.keys.toSet(), <String>{'PH-owner', 'PC-1'});
      expect(byId['PH-owner']!.online, isTrue);
      expect(byId['PH-owner']!.lastSeenMillis, 1700000000000);
      expect(byId['PC-1']!.online, isFalse);
      expect(byId['PC-1']!.lastSeenMillis, 1699999999000);
    });

    test(
      'contract: a device with no presence record is absent, not faked',
      () async {
        final HttpSnapshotSource source = _source(
          backend: backendMock(
            <Map<String, dynamic>>[
              _device('PH-owner', 'owner_phone'),
              _device('PC-1', 'computer'),
            ],
            presence: <String, Map<String, dynamic>>{
              'PC-1': _presence('PC-1', online: true),
            },
          ),
        );

        final Map<String, Presence> byId = await source.fetchPresence();

        // A missing record is normal, so the map still lands and the gap
        // reads as offline through deviceStateOf. A faked row would
        // invent a last_seen the backend never reported.
        expect(byId.keys.toList(), <String>['PC-1']);
        expect(byId.containsKey('PH-owner'), isFalse);
      },
    );

    test('contract: the owner id is derived from the owner_phone role', () async {
      final HttpSnapshotSource source = _source(
        backend: backendMock(<Map<String, dynamic>>[
          _device('PH-2', 'trusted_phone', displayName: 'Spare'),
          _device('PH-owner', 'owner_phone', displayName: 'Owner Pixel'),
          _device('PC-1', 'computer', displayName: 'WIN-PC'),
        ]),
      );

      // The owner sits second in the list, so this fails if the source
      // takes the first phone instead of the owner role.
      expect(await source.fetchOwnerDeviceId(), 'PH-owner');
    });

    test('contract: no owner role yields an empty id, never a stand-in', () async {
      final HttpSnapshotSource source = _source(
        backend: backendMock(<Map<String, dynamic>>[
          _device('PH-2', 'trusted_phone', displayName: 'Spare'),
          _device('PC-1', 'computer', displayName: 'WIN-PC'),
        ]),
      );

      // Standing in the first device would badge a spare phone as
      // Owner and hide its revoke button.
      expect(await source.fetchOwnerDeviceId(), '');
    });

    test('contract: one refresh costs one devices call', () async {
      final List<http.Request> seen = <http.Request>[];
      final HttpSnapshotSource source = _source(
        backend: backendMock(
          <Map<String, dynamic>>[
            _device('PH-owner', 'owner_phone'),
            _device('PC-1', 'computer'),
          ],
          presence: <String, Map<String, dynamic>>{
            'PH-owner': _presence('PH-owner', online: true),
            'PC-1': _presence('PC-1', online: true),
          },
          seen: seen,
        ),
      );

      // The order a first pull refresh runs in, from
      // DevicesController.refresh.
      await source.fetchDevices();
      final Map<String, Presence> byId = await source.fetchPresence();
      expect(await source.fetchOwnerDeviceId(), 'PH-owner');

      expect(byId.keys.toSet(), <String>{'PH-owner', 'PC-1'});
      expect(
        seen.map((http.Request request) => request.url.path).toList(),
        <String>[
          '/v1/devices',
          '/v1/computers/PH-owner/presence',
          '/v1/computers/PC-1/presence',
        ],
      );
    });

    test(
      'contract: a token change re-reads devices instead of reusing them',
      () async {
        int deviceCalls = 0;
        final HttpSnapshotSource source = _source(
          backend: MockClient((http.Request request) async {
            deviceCalls += 1;
            return _json(<String, dynamic>{
              'devices': <Map<String, dynamic>>[
                _device(deviceCalls == 1 ? 'PH-a' : 'PH-b', 'owner_phone'),
              ],
            });
          }),
        );

        expect(await source.fetchOwnerDeviceId(), 'PH-a');

        // A re-login carries a new bearer token, so the previous
        // session's device list must never decide who the Owner is.
        source.api.token = 'tok-456';

        expect(await source.fetchOwnerDeviceId(), 'PH-b');
        expect(deviceCalls, 2);
      },
    );

    test('contract: a backend failure surfaces, not an empty list', () {
      final HttpSnapshotSource source = _source(
        backend: MockClient((http.Request request) async {
          return _json(
            <String, dynamic>{
              'error': ApiCodes.revoked,
              'message': 'device revoked',
              'retryable': false,
            },
            status: 401,
          );
        }),
      );

      expect(
        source.fetchDevices(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiCodes.revoked)
              .having((e) => e.status, 'status', 401),
        ),
      );
    });
  });

  group('computer and workflow snapshots from the agent channel', () {
    test(
      'contract: the computer snapshot carries its header and rows',
      () async {
        final List<http.Request> seen = <http.Request>[];
        final HttpSnapshotSource source = _source(
          agent: agentMock(
            <String, dynamic>{
              'device_id': 'PC-1',
              'display_name': 'WIN-PC',
              'online': true,
              'last_seen_millis': 1700000000000,
              'workflows': <Map<String, dynamic>>[
                <String, dynamic>{
                  'workflow_id': 'wf-1',
                  'computer_id': 'PC-1',
                  'title': 'Build app',
                  'status': 'running',
                },
                <String, dynamic>{
                  'workflow_id': 'wf-2',
                  'computer_id': 'PC-1',
                  'title': 'Review PR',
                  'status': 'waiting_approval',
                },
              ],
            },
            seen: seen,
          ),
        );

        final ComputerSnapshot snap = await source.fetchComputer('PC-1');

        expect(snap.deviceId, 'PC-1');
        expect(snap.displayName, 'WIN-PC');
        expect(snap.online, isTrue);
        expect(snap.lastSeenMillis, 1700000000000);
        expect(
          snap.workflows
              .map((WorkflowRow row) => '${row.workflowId}:${row.title}')
              .toList(),
          <String>['wf-1:Build app', 'wf-2:Review PR'],
        );
        expect(snap.workflows.last.status, 'waiting_approval');
        expect(seen.single.url.path, '/v1/agent/computers/PC-1');
        expect(seen.single.headers['Authorization'], 'Bearer tok-123');
      },
    );

    test(
      'contract: a non-object workflow row is dropped, not blanked',
      () async {
        final HttpSnapshotSource source = _source(
          agent: agentMock(<String, dynamic>{
            'device_id': 'PC-1',
            'display_name': 'WIN-PC',
            'online': true,
            'last_seen_millis': 1700000000000,
            'workflows': <dynamic>[
              'not-a-row',
              <String, dynamic>{
                'workflow_id': 'wf-1',
                'computer_id': 'PC-1',
                'title': 'Build app',
                'status': 'running',
              },
            ],
          }),
        );

        final ComputerSnapshot snap = await source.fetchComputer('PC-1');

        expect(
          snap.workflows.map((WorkflowRow row) => row.workflowId).toList(),
          <String>['wf-1'],
        );
      },
    );

    test(
      'contract: buffers carry the cap totals, flags, and seq mark',
      () async {
        final List<http.Request> seen = <http.Request>[];
        final HttpSnapshotSource source = _source(
          agent: agentMock(
            <String, dynamic>{
              'workflow_id': 'wf-1',
              'computer_id': 'PC-1',
              'status': 'waiting_input',
              'last_seq_no': 42,
              'activity': <Map<String, dynamic>>[
                <String, dynamic>{
                  'event_id': 'e-1',
                  'event_type': 'step',
                  'summary': 'ran build',
                  'occurred_at_millis': 1700000000000,
                  'seq_no': 41,
                },
              ],
              'chat': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message_id': 'm-1',
                  'body': 'hi',
                  'outbound': true,
                  'send_state': 'sent',
                  'seq_no': 42,
                },
              ],
              'terminal_lines': <String>['line one', 'line two'],
              'terminal_total_lines': 9000,
              'files': <Map<String, dynamic>>[
                <String, dynamic>{
                  'path': 'a.dart',
                  'diff': '--- a',
                  'truncated': false,
                },
                <String, dynamic>{
                  'path': 'b.dart',
                  'diff': '--- b',
                  'truncated': true,
                },
              ],
              'files_truncated': true,
              'approvals': <Map<String, dynamic>>[
                <String, dynamic>{
                  'approval_id': 'ap-1',
                  'workflow_id': 'wf-1',
                  'title': 'Delete build',
                  'detail': 'rm -rf out',
                  'expires_at_millis': 1700000600000,
                  'destructive': true,
                },
              ],
            },
            seen: seen,
          ),
        );

        final WorkflowBuffers buffers = await source.fetchWorkflow('PC-1', 'wf-1');

        expect(buffers.workflowId, 'wf-1');
        expect(buffers.computerId, 'PC-1');
        expect(buffers.status, 'waiting_input');
        // The high-water mark is what drops every live delta at or
        // below it, so it has to survive the parse intact.
        expect(buffers.lastSeqNo, 42);
        expect(buffers.activity.single.id, 'e-1');
        expect(buffers.activity.single.seqNo, 41);
        expect(buffers.chat.single.messageId, 'm-1');
        expect(buffers.chat.single.outbound, isTrue);
        expect(buffers.terminalLines, <String>['line one', 'line two']);
        // The totals announce truncation, the rows stay the agent tail.
        expect(buffers.terminalTotalLines, 9000);
        expect(
          buffers.files.map((BufferedFile hunk) => hunk.path).toList(),
          <String>['a.dart', 'b.dart'],
        );
        expect(buffers.files.last.truncated, isTrue);
        expect(buffers.filesTruncated, isTrue);
        expect(buffers.approvals.single.approvalId, 'ap-1');
        expect(buffers.approvals.single.destructive, isTrue);
        expect(buffers.approvals.single.isResolved, isFalse);
        expect(
          seen.single.url.path,
          '/v1/agent/computers/PC-1/workflows/wf-1',
        );
        expect(seen.single.headers['Authorization'], 'Bearer tok-123');
      },
    );

    test(
      'contract: buffer rows without their id are dropped, never blanked',
      () async {
        final HttpSnapshotSource source = _source(
          agent: agentMock(<String, dynamic>{
            'workflow_id': 'wf-1',
            'computer_id': 'PC-1',
            'status': 'running',
            'last_seq_no': 7,
            'activity': <dynamic>[
              'not-a-row',
              <String, dynamic>{'event_type': 'step', 'summary': 'orphan'},
            ],
            'chat': <dynamic>[
              <String, dynamic>{'body': 'orphan'},
            ],
            'files': <dynamic>[
              <String, dynamic>{'diff': '--- orphan'},
            ],
            'approvals': <dynamic>[
              <String, dynamic>{'title': 'orphan'},
            ],
          }),
        );

        final WorkflowBuffers buffers = await source.fetchWorkflow('PC-1', 'wf-1');

        // A blanked row would key activity, chat, and approvals off one
        // empty id and collapse them into each other on the next insert.
        expect(buffers.activity, isEmpty);
        expect(buffers.chat, isEmpty);
        expect(buffers.files, isEmpty);
        expect(buffers.approvals, isEmpty);
        // Dropping rows never blanks the snapshot header.
        expect(buffers.lastSeqNo, 7);
        expect(buffers.status, 'running');
      },
    );

    test('contract: an agent failure arrives as a Future error', () {
      final HttpSnapshotSource source = _source(
        agent: agentMock(<String, dynamic>{}, status: 503),
      );

      expect(
        source.fetchComputer('PC-1'),
        throwsA(
          isA<AgentException>()
              .having((e) => e.code, 'code', AgentCodes.snapshotMissed)
              .having((e) => e.status, 'status', 503)
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );

      // 401 must not fold into the retryable branch, or a revoked token
      // buys a reconnect loop instead of a logout.
      final HttpSnapshotSource unauthorized = _source(
        agent: agentMock(<String, dynamic>{}, status: 401),
      );

      expect(
        unauthorized.fetchWorkflow('PC-1', 'wf-1'),
        throwsA(
          isA<AgentException>()
              .having((e) => e.code, 'code', AgentCodes.unauthorized)
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('contract: a non-object agent body fails the fetch', () {
      final HttpSnapshotSource source = _source(agent: agentMock(<int>[1, 2, 3]));

      // A proxy or a wrong path can answer with a JSON array. Reading
      // that as buffers would render an empty workflow as a real one.
      expect(
        source.fetchComputer('PC-1'),
        throwsA(
          isA<AgentException>().having((e) => e.status, 'status', 500),
        ),
      );
    });
  });

  group('the app shell override', () {
    test('contract: the override wires both base urls and the token', () {
      final SnapshotSource source = buildHttpSnapshotSource(
        apiBaseUrl: 'https://backend.test',
        agentBaseUrl: 'https://agent.test/',
        token: 'tok-123',
      );

      final HttpSnapshotSource http = source as HttpSnapshotSource;
      addTearDown(http.agent.close);

      expect(http.api.baseUrl, 'https://backend.test');
      expect(http.api.token, 'tok-123');
      // The mesh url takes the agent client's own trailing-slash trim,
      // so a shell holding either form addresses one host.
      expect(http.agent.baseUrl, 'https://agent.test');
      expect(http.agent.token, 'tok-123');
    });

    test('contract: an injected client is used as given', () async {
      bool called = false;
      final CalcarApiClient api = CalcarApiClient(
        baseUrl: 'https://backend.test',
        token: 'tok-123',
        httpClient: MockClient((http.Request request) async {
          called = true;
          return _json(<String, dynamic>{
            'devices': <Map<String, dynamic>>[_device('PC-1', 'computer')],
          });
        }),
      );

      final SnapshotSource source = buildHttpSnapshotSource(
        apiBaseUrl: 'https://unused.test',
        agentBaseUrl: 'https://agent.test',
        token: 'tok-123',
        apiClient: api,
      );

      final HttpSnapshotSource http = source as HttpSnapshotSource;
      addTearDown(http.agent.close);
      final List<Device> devices = await http.fetchDevices();

      expect(devices.single.deviceId, 'PC-1');
      expect(called, isTrue);
      // The injected side wins, the other side is still built here.
      expect(http.agent.baseUrl, 'https://agent.test');
      expect(http.agent.token, 'tok-123');
    });
  });
}
