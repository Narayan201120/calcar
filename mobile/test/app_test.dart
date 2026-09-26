/// App shell contracts: deep links out of push ids, the cold start
/// phase, the foreground socket lifetime, push token registration,
/// payload privacy, and the first run lock.
///
/// Fakes only. No network (MockClient), no platform channel, no socket
/// (the realtime provider is overridden, so nothing dials), no real
/// biometrics. Each test names the contract it guards.
library;

import 'dart:async';
import 'dart:convert';

import 'package:calcar/api/api.dart';
import 'package:calcar/app.dart';
import 'package:calcar/push/push_service.dart';
import 'package:calcar/realtime/realtime.dart';
import 'package:calcar/screens/first_run.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Real clock, because the workflow screen derives approval expiry
/// against the wall clock at build time.
final int _now = DateTime.now().millisecondsSinceEpoch;

const DeepLink _computerLink = DeepLink(
  kind: DeepLinkKind.computer,
  computerId: 'PC-1',
);

const DeepLink _workflowLink = DeepLink(
  kind: DeepLinkKind.workflow,
  computerId: 'PC-1',
  workflowId: 'wf-1',
);

const DeepLink _approvalLink = DeepLink(
  kind: DeepLinkKind.approval,
  computerId: 'PC-1',
  workflowId: 'wf-1',
  approvalId: 'ap-1',
);

Device _device({
  required String deviceId,
  required String role,
  required String displayName,
}) {
  return Device(
    deviceId: deviceId,
    role: role,
    displayName: displayName,
    pubkeyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    fingerprint: 'A91C 7D24',
    revoked: false,
    authorizedBy: 'PH-owner',
  );
}

ComputerSnapshot _computer() {
  return ComputerSnapshot(
    deviceId: 'PC-1',
    displayName: 'WIN-PC',
    online: true,
    lastSeenMillis: _now,
    workflows: const <WorkflowRow>[
      WorkflowRow(
        workflowId: 'wf-1',
        computerId: 'PC-1',
        title: 'Build app',
        status: 'running',
      ),
      WorkflowRow(
        workflowId: 'wf-2',
        computerId: 'PC-1',
        title: 'Deploy prod',
        status: 'waiting_approval',
      ),
    ],
  );
}

WorkflowBuffers _buffers() {
  return WorkflowBuffers(
    workflowId: 'wf-1',
    computerId: 'PC-1',
    status: 'waiting_approval',
    lastSeqNo: 10,
    activity: <BufferedActivity>[
      BufferedActivity(
        id: 'e-1',
        kind: 'started',
        text: 'started',
        atMillis: _now - 60000,
        seqNo: 9,
      ),
    ],
    chat: <BufferedChat>[
      BufferedChat(messageId: 'm-1', body: 'build it', seqNo: 10),
    ],
    terminalLines: const <String>['cloning repo'],
    terminalTotalLines: 1,
    approvals: <TrackedApproval>[
      TrackedApproval(
        approvalId: 'ap-1',
        workflowId: 'wf-1',
        title: 'Run the migration',
        detail: 'alembic upgrade head',
        expiresAtMillis: _now + 90000,
        destructive: true,
      ),
      TrackedApproval(
        approvalId: 'ap-old',
        workflowId: 'wf-1',
        title: 'Old approval',
        detail: 'too late',
        expiresAtMillis: _now - 1000,
        resolution: 'rejected',
      ),
    ],
  );
}

Map<String, dynamic> _sentBody(http.Request request) {
  return jsonDecode(request.body) as Map<String, dynamic>;
}

/// Snapshot source with canned data and call counters. [order] records
/// which half of a cold start ran first, [deviceGate] holds the device
/// refresh open so the cached frame is observable, and [failDevices]
/// makes that refresh fail.
class _FakeSnapshotSource implements SnapshotSource {
  _FakeSnapshotSource({this.order});

  final List<String>? order;
  Completer<List<Device>>? deviceGate;
  bool failDevices = false;
  int workflowFetches = 0;

  @override
  Future<List<Device>> fetchDevices() {
    order?.add('refresh');
    if (failDevices) {
      return Future<List<Device>>.error(StateError('network down'));
    }
    final Completer<List<Device>>? gate = deviceGate;
    if (gate != null) {
      return gate.future;
    }
    return Future<List<Device>>.value(<Device>[
      _device(
        deviceId: 'PH-owner',
        role: 'owner_phone',
        displayName: 'Owner Pixel',
      ),
      _device(
        deviceId: 'PC-1',
        role: 'computer',
        displayName: 'WIN-PC',
      ),
    ]);
  }

  @override
  Future<Map<String, Presence>> fetchPresence() {
    return Future<Map<String, Presence>>.value(<String, Presence>{
      'PC-1': Presence(deviceId: 'PC-1', online: true, lastSeenMillis: _now),
    });
  }

  @override
  Future<String> fetchOwnerDeviceId() {
    return Future<String>.value('PH-owner');
  }

  @override
  Future<ComputerSnapshot> fetchComputer(String computerId) {
    return Future<ComputerSnapshot>.value(_computer());
  }

  @override
  Future<WorkflowBuffers> fetchWorkflow(
    String computerId,
    String workflowId,
  ) {
    workflowFetches += 1;
    return Future<WorkflowBuffers>.value(_buffers());
  }
}

class _FakeColdStartSource implements ColdStartSource {
  _FakeColdStartSource(this.rows, {this.order});

  final int rows;
  final List<String>? order;

  @override
  Future<CacheProbe> readCache() async {
    order?.add('cache');
    return CacheProbe(rows);
  }
}

class _FakeTokenSource implements PushTokenSource {
  _FakeTokenSource(this.platform, this.token);

  @override
  final PushPlatform platform;

  String? token;
  int reads = 0;

  @override
  Future<String?> readToken() async {
    reads += 1;
    return token;
  }
}

class _FakeGate implements LocalAuthGate {
  _FakeGate(this.result);

  LocalAuthResult result;
  int calls = 0;
  String lastReason = '';

  @override
  Future<LocalAuthResult> authenticate({required String reason}) async {
    calls += 1;
    lastReason = reason;
    return result;
  }
}

/// Counts how often the shell watches the foreground socket, and proves
/// it never dials: the channel factory would throw if the shell reached
/// past the binding.
class _SocketWatch {
  int created = 0;
  int disposed = 0;
  int dials = 0;
}

Override _realtimeOverride(_SocketWatch watch) {
  return realtimeBindingProvider.overrideWith((Ref ref) {
    watch.created += 1;
    ref.onDispose(() {
      watch.disposed += 1;
    });
    return RealtimeBinding(
      socket: CalcarSocketClient(
        baseUrl: 'wss://example.invalid',
        userId: 'u1',
        token: 'tok',
        channelFactory: (Uri uri, Iterable<String>? protocols) {
          watch.dials += 1;
          throw StateError('no sockets in widget tests');
        },
      ),
    );
  });
}

/// Every app pump needs a snapshot source and a socket override, since
/// the shell watches the socket provider from every view but first run.
List<Override> _overrides({
  required _FakeSnapshotSource source,
  _SocketWatch? watch,
  ColdStartSource? coldStart,
}) {
  return <Override>[
    snapshotSourceProvider.overrideWithValue(source),
    _realtimeOverride(watch ?? _SocketWatch()),
    if (coldStart != null) coldStartSourceProvider.overrideWithValue(coldStart),
  ];
}

/// Mock control plane. [statuses] answers each request in turn and the
/// last one repeats, so a test can fail one post and accept the next.
CalcarApiClient _api(
  List<http.Request> sent, {
  List<int> statuses = const <int>[200],
  String errorBody = 'canned',
}) {
  int seen = 0;
  return CalcarApiClient(
    baseUrl: 'https://backend.test',
    token: 'tok-123',
    httpClient: MockClient((http.Request request) async {
      sent.add(request);
      final int last = statuses.length - 1;
      final int status = statuses[seen < last ? seen : last];
      seen += 1;
      if (status >= 400) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'error': errorBody,
            'retryable': false,
          }),
          status,
          headers: <String, String>{'Content-Type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'device_id': 'PH-owner',
          'platform': 'fcm',
        }),
        status,
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }),
  );
}

CalcarShellDeps _deps() {
  return CalcarShellDeps(
    api: _api(<http.Request>[]),
    authGate: _FakeGate(LocalAuthResult.unlocked),
    onEstablishOwner: (String displayName) async => true,
  );
}

Widget _app({
  required DeepLinkBus bus,
  required List<Override> overrides,
  CalcarStart start = CalcarStart.computers,
  String? initialRoute,
}) {
  return ProviderScope(
    overrides: overrides,
    child: CalcarApp(
      deps: _deps(),
      start: start,
      deepLinkBus: bus,
      initialRoute: initialRoute,
    ),
  );
}

PushService _push({
  required _FakeSnapshotSource source,
  required DeepLinkBus bus,
  List<PushTokenSource> tokens = const <PushTokenSource>[],
  List<String>? log,
  List<http.Request>? sent,
  List<int> statuses = const <int>[200],
  String errorBody = 'canned',
}) {
  return PushService(
    api: _api(
      sent ?? <http.Request>[],
      statuses: statuses,
      errorBody: errorBody,
    ),
    source: source,
    bus: bus,
    deviceId: 'PH-owner',
    tokenSources: tokens,
    log: log?.add,
    requestId: () => 'req-1',
  );
}

void main() {
  group('push ids route to the screen that addresses them', () {
    testWidgets(
      'contract: a body with a computer id opens the computer screen',
      (WidgetTester tester) async {
        final DeepLinkBus bus = DeepLinkBus();
        final _FakeSnapshotSource source = _FakeSnapshotSource();
        await tester.pumpWidget(
          _app(bus: bus, overrides: _overrides(source: source)),
        );
        await tester.pumpAndSettle();

        // The tap is fired, not awaited: a widget test owns the clock, so
        // pumpAndSettle is what lets the service finish and the route
        // build.
        unawaited(
          _push(source: source, bus: bus).onNotificationOpened(
            <String, dynamic>{
              'kind': 'completed',
              'computer_id': 'PC-1',
              'workflow_id': '',
            },
          ),
        );
        await tester.pumpAndSettle();

        expect(bus.pending!.link, _computerLink);
        expect(find.widgetWithText(AppBar, 'WIN-PC'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('workflow-row-wf-1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('workflow-row-wf-2')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'contract: a body with a workflow id opens the workflow screen',
      (WidgetTester tester) async {
        final DeepLinkBus bus = DeepLinkBus();
        final _FakeSnapshotSource source = _FakeSnapshotSource();
        await tester.pumpWidget(
          _app(bus: bus, overrides: _overrides(source: source)),
        );
        await tester.pumpAndSettle();

        unawaited(
          _push(source: source, bus: bus).onNotificationOpened(
            <String, dynamic>{
              'kind': 'input_required',
              'computer_id': 'PC-1',
              'workflow_id': 'wf-1',
            },
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('workflow-PC-1-wf-1')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('event-e-1')), findsOneWidget);
        // A workflow link carries no approval target.
        expect(
          find.byKey(const ValueKey('workflow-PC-1-wf-1-approval-ap-1')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'contract: an approval body opens the workflow on that approval',
      (WidgetTester tester) async {
        final DeepLinkBus bus = DeepLinkBus();
        final _FakeSnapshotSource source = _FakeSnapshotSource();
        await tester.pumpWidget(
          _app(bus: bus, overrides: _overrides(source: source)),
        );
        await tester.pumpAndSettle();

        unawaited(
          _push(source: source, bus: bus).onNotificationOpened(
            <String, dynamic>{
              'kind': 'approval_required',
              'computer_id': 'PC-1',
              'workflow_id': 'wf-1',
              'approval_id': 'ap-1',
            },
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('workflow-PC-1-wf-1-approval-ap-1')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('approval-ap-1')), findsOneWidget);
      },
    );

    testWidgets(
      'contract: a cold start from a link path opens the same screen',
      (WidgetTester tester) async {
        final _FakeSnapshotSource source = _FakeSnapshotSource();
        await tester.pumpWidget(
          _app(
            bus: DeepLinkBus(),
            overrides: _overrides(source: source),
            initialRoute: _approvalLink.path,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('workflow-PC-1-wf-1-approval-ap-1')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('route-unknown')), findsNothing);
      },
    );
  });

  group('foreground socket lifetime', () {
    testWidgets(
      'contract: the socket is mounted only while a view is watched',
      (WidgetTester tester) async {
        final _SocketWatch watch = _SocketWatch();
        final DeepLinkBus bus = DeepLinkBus();
        await tester.pumpWidget(
          _app(
            bus: bus,
            start: CalcarStart.firstRun,
            overrides: _overrides(
              source: _FakeSnapshotSource(),
              watch: watch,
            ),
          ),
        );
        await tester.pumpAndSettle();
        // First run has no authenticated session, so nothing holds the
        // socket open.
        expect(watch.created, 0);

        bus.open(
          DeepLinkRequest(
            link: _workflowLink,
            detail: WorkflowBuffersDetail(_buffers()),
          ),
        );
        await tester.pumpAndSettle();
        expect(watch.created, 1);
        expect(watch.disposed, 0);
        expect(watch.dials, 0);

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(watch.disposed, 1);
      },
    );
  });

  group('cold start', () {
    testWidgets(
      'contract: the cache is read before the refresh and drops when it lands',
      (WidgetTester tester) async {
        final List<String> order = <String>[];
        final _FakeSnapshotSource source = _FakeSnapshotSource(order: order);
        source.deviceGate = Completer<List<Device>>();
        await tester.pumpWidget(
          _app(
            bus: DeepLinkBus(),
            overrides: _overrides(
              source: source,
              coldStart: _FakeColdStartSource(2, order: order),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('cold-start-cache-strip')),
          findsOneWidget,
        );
        expect(find.text('Restoring 2 cached devices'), findsOneWidget);
        expect(order, <String>['cache', 'refresh']);

        source.deviceGate!.complete(<Device>[]);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('cold-start-cache-strip')),
          findsNothing,
        );
        expect(find.text('No computers yet'), findsOneWidget);
      },
    );

    testWidgets(
      'contract: a failed refresh keeps the cached frame instead of blanking',
      (WidgetTester tester) async {
        final _FakeSnapshotSource source = _FakeSnapshotSource();
        source.failDevices = true;
        await tester.pumpWidget(
          _app(
            bus: DeepLinkBus(),
            overrides: _overrides(
              source: source,
              coldStart: _FakeColdStartSource(2),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('cold-start-refresh-failed')),
          findsOneWidget,
        );
        expect(
          find.text('Could not refresh. Showing the last known list.'),
          findsOneWidget,
        );
        // A dropped network must not read as a phone with no computers.
        expect(find.text('No computers yet'), findsOneWidget);
      },
    );
  });

  group('push token registration', () {
    test(
      'contract: an FCM and an APNs token each post once and never again',
      () async {
        final List<http.Request> sent = <http.Request>[];
        final _FakeTokenSource fcm =
            _FakeTokenSource(PushPlatform.fcm, 'fcm-token-a');
        final _FakeTokenSource apns =
            _FakeTokenSource(PushPlatform.apns, 'apns-token-b');
        final PushService push = _push(
          source: _FakeSnapshotSource(),
          bus: DeepLinkBus(),
          tokens: <PushTokenSource>[fcm, apns],
          sent: sent,
        );

        expect(await push.register(), 2);
        expect(sent.length, 2);
        expect(sent.first.method, 'POST');
        expect(sent.first.url.path, '/v1/devices/PH-owner/push-token');
        expect(sent.first.headers['X-Request-ID'], 'req-1');
        expect(_sentBody(sent.first)['platform'], 'fcm');
        expect(_sentBody(sent.first)['push_token'], 'fcm-token-a');
        expect(_sentBody(sent[1])['platform'], 'apns');
        expect(_sentBody(sent[1])['push_token'], 'apns-token-b');

        // A resume with unchanged tokens posts nothing.
        expect(await push.register(), 0);
        expect(sent.length, 2);
      },
    );

    test(
      'contract: a rotated token posts again, an absent one sends nothing',
      () async {
        final List<http.Request> sent = <http.Request>[];
        final _FakeTokenSource fcm =
            _FakeTokenSource(PushPlatform.fcm, 'fcm-token-a');
        final _FakeTokenSource pending =
            _FakeTokenSource(PushPlatform.apns, null);
        final PushService push = _push(
          source: _FakeSnapshotSource(),
          bus: DeepLinkBus(),
          tokens: <PushTokenSource>[fcm, pending],
          sent: sent,
        );

        expect(await push.register(), 1);
        expect(sent.length, 1);

        fcm.token = 'fcm-token-rotated';
        expect(await push.register(), 1);
        expect(sent.length, 2);
        expect(_sentBody(sent[1])['push_token'], 'fcm-token-rotated');
        expect(
          sent.map((http.Request request) => _sentBody(request)['platform']),
          <String>['fcm', 'fcm'],
        );
        expect(pending.reads, 2);
      },
    );

    test(
      'contract: a rejected post accepts nothing and the next one retries',
      () async {
        final List<http.Request> sent = <http.Request>[];
        final List<String> log = <String>[];
        final PushService push = _push(
          source: _FakeSnapshotSource(),
          bus: DeepLinkBus(),
          tokens: <PushTokenSource>[
            _FakeTokenSource(PushPlatform.fcm, 'fcm-token-a'),
          ],
          sent: sent,
          statuses: <int>[401, 200],
          log: log,
        );

        expect(await push.register(), 0);
        expect(sent.length, 1);
        expect(log.single, contains('tokenRegistrationFailed'));
        expect(log.single, contains('status=unauthorized'));

        // The token was never accepted, so the next register tries again.
        expect(await push.register(), 1);
        expect(sent.length, 2);
        expect(log.last, contains('tokenRegistered'));
      },
    );
  });

  group('push payload handling', () {
    test(
      'contract: a tap fetches the full detail and opens the addressed link',
      () async {
        final DeepLinkBus bus = DeepLinkBus();
        final _FakeSnapshotSource source = _FakeSnapshotSource();
        final PushService push = _push(source: source, bus: bus);

        final DeepLinkRequest? request =
            await push.onNotificationOpened(<String, dynamic>{
          'kind': 'approval_required',
          'computer_id': 'PC-1',
          'workflow_id': 'wf-1',
          'approval_id': 'ap-1',
        });

        expect(source.workflowFetches, 1);
        expect(request, isNotNull);
        expect(request!.link, _approvalLink);
        expect(bus.pending, request);
        final DeepLinkDetail detail = request.detail!;
        expect(detail, isA<WorkflowBuffersDetail>());
        expect(
          (detail as WorkflowBuffersDetail).buffers.workflowId,
          'wf-1',
        );
      },
    );

    test(
      'contract: a body with no computer id opens nothing, a new kind routes',
      () async {
        final DeepLinkBus bus = DeepLinkBus();
        final PushService push = _push(
          source: _FakeSnapshotSource(),
          bus: bus,
        );

        expect(
          await push.onNotificationOpened(<String, dynamic>{
            'kind': 'approval_required',
            'workflow_id': 'wf-1',
          }),
          isNull,
        );
        expect(bus.pending, isNull);

        // Additive only: a kind this build has never seen still routes.
        final DeepLinkRequest? future = await push.onNotificationOpened(
          <String, dynamic>{
            'kind': 'tool_call_waiting',
            'computer_id': 'PC-1',
            'workflow_id': 'wf-1',
          },
        );
        expect(future, isNotNull);
        expect(future!.link.kind, DeepLinkKind.workflow);
        expect(bus.pending, future);
      },
    );

    test(
      'contract: nothing from the body or the token reaches a log line',
      () async {
        final List<String> log = <String>[];
        final DeepLinkBus bus = DeepLinkBus();
        final PushService push = _push(
          source: _FakeSnapshotSource(),
          bus: bus,
          tokens: <PushTokenSource>[
            _FakeTokenSource(PushPlatform.fcm, 'token-secret-xyz'),
          ],
          log: log,
        );
        await push.register();
        await push.onNotificationOpened(<String, dynamic>{
          'kind': 'approval_required',
          'computer_id': 'PC-secret',
          'workflow_id': 'wf-secret',
          'approval_id': 'ap-secret',
          // Content a body must never be able to smuggle through.
          'source_path': r'C:\Users\owner\main.rs',
          'prompt': 'drop the prod database',
        });

        expect(log, isNotEmpty);
        final String joined = log.join('\n');
        expect(joined, isNot(contains('token-secret-xyz')));
        expect(joined, isNot(contains('PC-secret')));
        expect(joined, isNot(contains('wf-secret')));
        expect(joined, isNot(contains('ap-secret')));
        expect(joined, isNot(contains('main.rs')));
        expect(joined, isNot(contains('drop the prod database')));
        // Only the log is empty of content: the tap still routed on ids.
        expect(bus.pending!.link.computerId, 'PC-secret');
      },
    );

    test(
      'contract: a backend error string is bucketed, never logged',
      () async {
        final List<String> log = <String>[];
        final PushService push = _push(
          source: _FakeSnapshotSource(),
          bus: DeepLinkBus(),
          tokens: <PushTokenSource>[
            _FakeTokenSource(PushPlatform.fcm, 'fcm-token-a'),
          ],
          log: log,
          statuses: <int>[400],
          errorBody: 'owner prompt was: drop the prod database',
        );

        expect(await push.register(), 0);
        expect(log.single, contains('status=clientError'));
        expect(log.single, isNot(contains('drop the prod database')));
      },
    );
  });

  group('first run', () {
    testWidgets(
      'contract: the lock blocks the list until the gate opens it',
      (WidgetTester tester) async {
        final _FakeGate gate = _FakeGate(LocalAuthResult.unlocked);
        final List<String> established = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: FirstRunScreen(
              gate: gate,
              onEstablishOwner: (String displayName) async {
                established.add(displayName);
                return true;
              },
            ),
          ),
        );

        expect(find.text('No computers yet'), findsNothing);

        await tester.enterText(
          find.byKey(const ValueKey('first-run-owner-name')),
          '  Owner Pixel  ',
        );
        await tester.tap(find.byKey(const ValueKey('first-run-owner-submit')));
        await tester.pumpAndSettle();

        expect(established, <String>['Owner Pixel']);
        expect(find.byKey(const ValueKey('first-run-unlock')), findsOneWidget);
        // The list stays hidden and no prompt fires on its own.
        expect(find.text('No computers yet'), findsNothing);
        expect(gate.calls, 0);

        await tester.tap(find.byKey(const ValueKey('first-run-unlock')));
        await tester.pumpAndSettle();

        expect(gate.calls, 1);
        expect(gate.lastReason, isNotEmpty);
        expect(find.text('No computers yet'), findsOneWidget);
        expect(find.byKey(const ValueKey('first-run-unlock')), findsNothing);
      },
    );

    testWidgets(
      'contract: a failed Owner setup never reaches the lock or the gate',
      (WidgetTester tester) async {
        final _FakeGate gate = _FakeGate(LocalAuthResult.unlocked);
        await tester.pumpWidget(
          MaterialApp(
            home: FirstRunScreen(
              gate: gate,
              onEstablishOwner: (String displayName) async => false,
            ),
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('first-run-owner-name')),
          'Owner Pixel',
        );
        await tester.tap(find.byKey(const ValueKey('first-run-owner-submit')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('first-run-owner-error')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('first-run-unlock')), findsNothing);
        expect(gate.calls, 0);
        expect(find.text('No computers yet'), findsNothing);
      },
    );

    testWidgets(
      'contract: a cancelled prompt stays locked, an unenrolled phone opts in',
      (WidgetTester tester) async {
        final _FakeGate gate = _FakeGate(LocalAuthResult.cancelled);
        await tester.pumpWidget(
          MaterialApp(
            home: FirstRunScreen(
              gate: gate,
              onEstablishOwner: (String displayName) async => true,
            ),
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('first-run-owner-name')),
          'Owner Pixel',
        );
        await tester.tap(find.byKey(const ValueKey('first-run-owner-submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('first-run-unlock')));
        await tester.pumpAndSettle();

        // A cancel is a decision, not an error, and it does not open.
        expect(find.byKey(const ValueKey('first-run-unlock')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('first-run-lock-error')),
          findsNothing,
        );
        expect(find.text('No computers yet'), findsNothing);

        gate.result = LocalAuthResult.unavailable;
        await tester.tap(find.byKey(const ValueKey('first-run-unlock')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('first-run-continue-unlocked')),
          findsOneWidget,
        );
        expect(find.text('No computers yet'), findsNothing);

        await tester.tap(
          find.byKey(const ValueKey('first-run-continue-unlocked')),
        );
        await tester.pumpAndSettle();

        expect(find.text('No computers yet'), findsOneWidget);
      },
    );
  });
}
