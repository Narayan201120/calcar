/// App shell: theme, route table, cold start phase, foreground socket
/// scope, and deep links out of push ids.
///
/// Shape of a run:
/// 1. [CalcarApp] builds a MaterialApp with [calcarTheme] and
///    [AppRoutes.generate].
/// 2. The home route paints [ColdStartGate]: the SQLite cache first, then
///    one live refresh. Both halves are providers the merge step
///    overrides, and the gate owns the phase only, never a second copy
///    of the list.
/// 3. Every view except first run sits inside [RealtimeScope], the only
///    place the foreground socket is watched. The provider is
///    auto-dispose, so popping the view closes the socket, and a pause
///    closes it without waiting for a frame. Background is push only, so
///    nothing outside a foreground view ever holds a socket.
/// 4. A push tap arrives as a [DeepLinkRequest] on a [DeepLinkBus], or as
///    [CalcarApp.initialRoute] on a cold start. The route paints the
///    detail the push path already fetched, then hands over to the state
///    layer so live deltas have a high-water mark.
///
/// No platform channel, no crypto, and no socket construction live here.
/// [CalcarShellDeps] carries the client, the local auth gate, and the
/// Owner bootstrap; the socket provider owns its own channel factory.
library;

import 'dart:async';

import 'package:calcar/api/api.dart';
import 'package:calcar/screens/first_run.dart';
import 'package:calcar/screens/wired/wired_add_computer.dart';
import 'package:calcar/screens/wired/wired_computer_detail.dart';
import 'package:calcar/screens/wired/wired_computers.dart';
import 'package:calcar/screens/wired/wired_devices.dart';
import 'package:calcar/screens/wired/wired_workflow_view.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One theme for the whole app, Material 3 on a fixed seed so status
/// chips, approval cards, and the lock screen read the same everywhere.
final ThemeData calcarTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: Color(0xFF2E6E4E)),
);

int _requestCounter = 0;

/// Fresh request id for a mutation. Monotonic per process and never
/// derived from a secret, so a retried send after a drop carries a new
/// idempotency key instead of replaying the old one.
String newRequestId() {
  _requestCounter += 1;
  return 'req-${DateTime.now().microsecondsSinceEpoch}-$_requestCounter';
}

/// Which screen a link's ids address.
enum DeepLinkKind {
  /// One computer: header plus workflow rows.
  computer,

  /// One workflow on one computer: activity, chat, terminal, files.
  workflow,

  /// One approval inside a workflow. Routes to the workflow screen with
  /// that approval as the target, since approvals live in its activity
  /// feed.
  approval,
}

/// A navigation target built from ids only.
///
/// The push body carries ids and kind, nothing else, so this holds ids
/// and the [kind] that says which screen they address. Two links are
/// equal when their kind and ids match, which is what lets a repeat tap
/// land on the same screen.
class DeepLink {
  final DeepLinkKind kind;
  final String computerId;
  final String workflowId;
  final String approvalId;

  const DeepLink({
    required this.kind,
    required this.computerId,
    this.workflowId = '',
    this.approvalId = '',
  });

  /// Route name from the table. The bus pushes by this name and hands
  /// the link over as the route arguments.
  String get routeName {
    switch (kind) {
      case DeepLinkKind.computer:
        return AppRoutes.computer;
      case DeepLinkKind.workflow:
        return AppRoutes.workflow;
      case DeepLinkKind.approval:
        return AppRoutes.approval;
    }
  }

  /// Path form. [CalcarApp.initialRoute] takes this, and it is the shape
  /// a link from outside the app would carry.
  String get path {
    switch (kind) {
      case DeepLinkKind.computer:
        return '/computers/${Uri.encodeComponent(computerId)}';
      case DeepLinkKind.workflow:
        return '/computers/${Uri.encodeComponent(computerId)}'
            '/workflows/${Uri.encodeComponent(workflowId)}';
      case DeepLinkKind.approval:
        return '/computers/${Uri.encodeComponent(computerId)}'
            '/workflows/${Uri.encodeComponent(workflowId)}'
            '/approvals/${Uri.encodeComponent(approvalId)}';
    }
  }

  /// Parses the path form back into a link.
  ///
  /// A cold start from a link builds one route per path segment, so an
  /// ancestor path resolves to its parent screen: a workflow link gets
  /// the computer screen underneath it and an approval link gets the
  /// workflow. That keeps the back stack real instead of leaving a dead
  /// frame under the target. A path that does not carry the ids its
  /// level needs is null, so a truncated or hand written link never
  /// routes to a half built screen.
  static DeepLink? tryParsePath(String path) {
    final List<String> parts = path
        .split('/')
        .where((String part) => part.isNotEmpty)
        .map(_decodeSegment)
        .toList(growable: false);
    if (parts.length < 2 || parts.length > 6) {
      return null;
    }
    if (parts[0] != 'computers' || parts[1].isEmpty) {
      return null;
    }
    final String computerId = parts[1];
    if (parts.length == 2) {
      return DeepLink(kind: DeepLinkKind.computer, computerId: computerId);
    }
    if (parts[2] != 'workflows') {
      return null;
    }
    if (parts.length == 3) {
      return DeepLink(kind: DeepLinkKind.computer, computerId: computerId);
    }
    if (parts[3].isEmpty) {
      return null;
    }
    final DeepLink workflow = DeepLink(
      kind: DeepLinkKind.workflow,
      computerId: computerId,
      workflowId: parts[3],
    );
    if (parts.length == 4) {
      return workflow;
    }
    if (parts[4] != 'approvals') {
      return null;
    }
    if (parts.length == 5) {
      return workflow;
    }
    if (parts[5].isEmpty) {
      return null;
    }
    return DeepLink(
      kind: DeepLinkKind.approval,
      computerId: computerId,
      workflowId: parts[3],
      approvalId: parts[5],
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DeepLink &&
        other.kind == kind &&
        other.computerId == computerId &&
        other.workflowId == workflowId &&
        other.approvalId == approvalId;
  }

  @override
  int get hashCode => Object.hash(kind, computerId, workflowId, approvalId);

  @override
  String toString() => 'DeepLink($kind, $computerId, $workflowId, $approvalId)';

  /// A link can arrive from outside the app, so a malformed escape is a
  /// broken link rather than a crash. An empty segment then fails the id
  /// checks below and the path parses to null.
  static String _decodeSegment(String segment) {
    try {
      return Uri.decodeComponent(segment);
    } on Object {
      return '';
    }
  }
}

/// Full detail fetched over the authenticated channel behind a push
/// body. Ids travel in the body; everything a screen renders arrives
/// through one of these, never through the notification.
abstract class DeepLinkDetail {
  const DeepLinkDetail();
}

/// Computer header plus its workflow rows.
class ComputerSnapshotDetail extends DeepLinkDetail {
  const ComputerSnapshotDetail(this.snapshot);

  final ComputerSnapshot snapshot;
}

/// Full workflow buffers, approvals included.
class WorkflowBuffersDetail extends DeepLinkDetail {
  const WorkflowBuffersDetail(this.buffers);

  final WorkflowBuffers buffers;
}

/// A deep link plus the detail already fetched for it.
///
/// [detail] is null when the link came from somewhere that did not
/// prefetch, in which case the route host fetches on mount.
class DeepLinkRequest {
  final DeepLink link;
  final DeepLinkDetail? detail;

  const DeepLinkRequest({required this.link, this.detail});

  String get routeName => link.routeName;
}

/// Carries a push tap to the app shell. The push service publishes a
/// [DeepLinkRequest]; [CalcarApp] listens and routes it. One pending
/// request at a time, which is all a tap needs: the newest tap wins.
class DeepLinkBus extends ChangeNotifier {
  DeepLinkRequest? _pending;

  /// The newest unpublished request, or null.
  DeepLinkRequest? get pending => _pending;

  /// Publishes a request to the shell.
  void open(DeepLinkRequest request) {
    _pending = request;
    notifyListeners();
  }
}

/// Route table. The names are the contract: the push bus pushes by name
/// and hands the link over as arguments, [CalcarApp.initialRoute] uses
/// the path form, and every builder lives behind [generate].
class AppRoutes {
  const AppRoutes._();

  /// My Computers. The home route.
  static const String computers = '/computers';

  /// Device management.
  static const String devices = '/devices';

  /// Add Computer, single use pairing flow.
  static const String addComputer = '/add-computer';

  /// Owner establish, then the lock, then the empty list.
  static const String firstRun = '/first-run';

  /// One computer, addressed by [DeepLink.computerId].
  static const String computer = '/computer';

  /// One workflow, addressed by computer id plus workflow id.
  static const String workflow = '/workflow';

  /// One approval, addressed by computer id, workflow id, approval id.
  static const String approval = '/approval';

  static bool isDeepLinkName(String name) {
    return name == computer || name == workflow || name == approval;
  }

  /// Resolves one route. The root route is [start], a known name builds
  /// its view, a link path or a link argument builds the addressed
  /// screen, and anything else lands on a dead end rather than a blank
  /// frame.
  static Route<dynamic> generate(
    RouteSettings settings,
    CalcarShellDeps deps,
    CalcarStart start,
  ) {
    final String? name = settings.name;
    final String routeName = name ?? '/';
    if (routeName == '/') {
      return _page(
        settings,
        start == CalcarStart.firstRun
            ? _firstRunView(deps)
            : _homeView(),
      );
    }
    if (routeName == computers) {
      return _page(settings, _homeView());
    }
    if (routeName == devices) {
      return _page(settings, _devicesView(deps));
    }
    if (routeName == addComputer) {
      return _page(
        settings,
        const RealtimeScope(child: WiredAddComputerScreen()),
      );
    }
    if (routeName == firstRun) {
      return _page(settings, _firstRunView(deps));
    }
    final DeepLinkRequest? request = requestFor(routeName, settings.arguments);
    if (request == null) {
      return _page(settings, _deadEndView(routeName));
    }
    if (request.link.kind == DeepLinkKind.computer) {
      return _page(settings, _computerView(request));
    }
    return _page(settings, _workflowView(request));
  }

  /// Recovers the request behind a route. Deep link names carry it in the
  /// arguments, path forms carry the ids in the name and may carry the
  /// fetched detail alongside.
  static DeepLinkRequest? requestFor(String name, Object? arguments) {
    if (arguments is DeepLinkRequest && isDeepLinkName(name)) {
      return arguments;
    }
    final DeepLink? link = DeepLink.tryParsePath(name);
    if (link == null) {
      return null;
    }
    return DeepLinkRequest(
      link: link,
      detail: arguments is DeepLinkDetail ? arguments : null,
    );
  }

  static MaterialPageRoute<void> _page(RouteSettings settings, Widget view) {
    return MaterialPageRoute<void>(
      builder: (_) => view,
      settings: settings,
    );
  }

  static Widget _homeView() {
    return const RealtimeScope(
      child: ColdStartGate(child: WiredComputersScreen()),
    );
  }

  static Widget _computerView(DeepLinkRequest request) {
    // The wired screen pushes the workflow itself with the title from the
    // row that was tapped. The state layer carries no workflow titles.
    final DeepLinkDetail? detail = request.detail;
    if (detail is ComputerSnapshotDetail) {
      return _seededComputer(request.link.computerId, detail.snapshot);
    }
    return RealtimeScope(
      child: WiredComputerDetailScreen(computerId: request.link.computerId),
    );
  }

  /// Renders the computer route from a prefetched snapshot, handed to the
  /// controller as a seed so the screen's own fetch is a no-op.
  static Widget _seededComputer(String computerId, ComputerSnapshot snap) {
    return _SeededScope(
      seed: (WidgetRef ref) {
        ref
            .read(computerControllerProvider(computerId).notifier)
            .seed(snap);
      },
      child: WiredComputerDetailScreen(computerId: computerId),
    );
  }

  static Widget _workflowView(DeepLinkRequest request) {
    final String approvalId = request.link.approvalId;
    final Widget view = WiredWorkflowView(
      workflow: WorkflowKey(
        computerId: request.link.computerId,
        workflowId: request.link.workflowId,
      ),
      title: request.link.workflowId,
      keyId: approvalId.isEmpty
          ? null
          : 'workflow-${request.link.computerId}'
              '-${request.link.workflowId}-approval-$approvalId',
    );
    final DeepLinkDetail? detail = request.detail;
    if (detail is WorkflowBuffersDetail) {
      return _SeededScope(
        seed: (WidgetRef ref) {
          ref
              .read(
                workflowControllerProvider(
                  WorkflowKey(
                    computerId: detail.buffers.computerId,
                    workflowId: detail.buffers.workflowId,
                  ),
                ).notifier,
              )
              .seed(detail.buffers);
        },
        child: view,
      );
    }
    return RealtimeScope(child: view);
  }

  static Widget _devicesView(CalcarShellDeps deps) {
    return RealtimeScope(
      child: WiredDevicesScreen(
        // A trust change needs a fresh auth at the moment it is sent, so
        // the wrapper owns that step and the wired screen refuses to
        // revoke without it.
        reauthenticate: (Device device) async {
          final LocalAuthResult auth = await deps.authGate.authenticate(
            reason: 'Revoke ${device.displayName}',
          );
          if (auth != LocalAuthResult.unlocked) {
            throw StateError('re-auth cancelled for ${device.deviceId}');
          }
        },
      ),
    );
  }

  static Widget _firstRunView(CalcarShellDeps deps) {
    return FirstRunScreen(
      gate: deps.authGate,
      onEstablishOwner: deps.onEstablishOwner,
    );
  }

  static Widget _deadEndView(String routeName) {
    return _DeadEndView(routeName: routeName);
  }
}

/// Merge step wiring the shell needs.
///
/// Every field needs a network client, a secure store, or a platform
/// channel, so none of it is built here. main.dart passes the real
/// client, the local auth backed gate, and the Owner bootstrap.
class CalcarShellDeps {
  final CalcarApiClient api;
  final LocalAuthGate authGate;
  final Future<bool> Function(String displayName) onEstablishOwner;

  const CalcarShellDeps({
    required this.api,
    required this.authGate,
    required this.onEstablishOwner,
  });
}

/// Where the shell starts. main.dart picks [firstRun] until an Owner
/// exists and [computers] after, so the cold start cache read and the
/// foreground socket only run once there is a session behind them.
enum CalcarStart {
  /// My Computers behind the cold start gate.
  computers,

  /// Owner establish, then the lock, then the empty list. No cache read
  /// and no socket, because there is no authenticated session yet.
  firstRun,
}

/// The app root. Owns the theme, the route table, and the deep link
/// bus.
///
/// [initialRoute] carries a push link on a cold start, where no bus is
/// listening yet. Flutter builds one route per path segment for it, and
/// [DeepLink.tryParsePath] resolves each ancestor to its parent screen,
/// so the back stack under the target is real.
class CalcarApp extends StatefulWidget {
  final CalcarShellDeps deps;
  final CalcarStart start;
  final DeepLinkBus? deepLinkBus;
  final String? initialRoute;

  const CalcarApp({
    super.key,
    required this.deps,
    this.start = CalcarStart.computers,
    this.deepLinkBus,
    this.initialRoute,
  });

  @override
  State<CalcarApp> createState() => _CalcarAppState();
}

class _CalcarAppState extends State<CalcarApp> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();
  DeepLinkBus? _bus;

  @override
  void initState() {
    super.initState();
    _attachBus();
  }

  @override
  void didUpdateWidget(CalcarApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deepLinkBus != widget.deepLinkBus) {
      _detachBus();
      _attachBus();
    }
  }

  @override
  void dispose() {
    _detachBus();
    super.dispose();
  }

  void _attachBus() {
    final DeepLinkBus? bus = widget.deepLinkBus;
    if (bus == null) {
      return;
    }
    _bus = bus;
    bus.addListener(_onDeepLink);
  }

  void _detachBus() {
    _bus?.removeListener(_onDeepLink);
    _bus = null;
  }

  void _onDeepLink() {
    final DeepLinkRequest? request = _bus?.pending;
    if (request == null) {
      return;
    }
    _navigator.currentState?.pushNamed(
      request.routeName,
      arguments: request,
    );
  }

  /// A push tap fetched full detail before publishing the link. Seeding it
  /// into the providers here is what lets the route skip its own fetch:
  /// one snapshot per open, whichever side got there first.
  static void seedDetail(WidgetRef ref, DeepLinkRequest request) {
    final DeepLinkDetail? detail = request.detail;
    if (detail is ComputerSnapshotDetail) {
      ref
          .read(computerControllerProvider(detail.snapshot.deviceId).notifier)
          .seed(detail.snapshot);
      return;
    }
    if (detail is WorkflowBuffersDetail) {
      ref
          .read(
            workflowControllerProvider(
              WorkflowKey(
                computerId: detail.buffers.computerId,
                workflowId: detail.buffers.workflowId,
              ),
            ).notifier,
          )
          .seed(detail.buffers);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calcar',
      theme: calcarTheme,
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      initialRoute: widget.initialRoute,
      onGenerateRoute: (RouteSettings settings) {
        return AppRoutes.generate(settings, widget.deps, widget.start);
      },
    );
  }
}

/// Wraps a route whose providers were already fed by a push prefetch. The
/// seed runs in a microtask, the same deferral the wired screens use, so
/// a provider is never written while the tree builds. The socket scope
/// still wraps the child, so a seeded route holds a socket exactly like
/// a fetched one.
class _SeededScope extends ConsumerStatefulWidget {
  final void Function(WidgetRef ref) seed;
  final Widget child;

  const _SeededScope({required this.seed, required this.child});

  @override
  ConsumerState<_SeededScope> createState() => _SeededScopeState();
}

class _SeededScopeState extends ConsumerState<_SeededScope> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() => widget.seed(ref));
  }

  @override
  Widget build(BuildContext context) {
    return RealtimeScope(child: widget.child);
  }
}

/// Foreground socket scope.
///
/// Watching [realtimeBindingProvider] is what keeps a socket open, and
/// that provider is auto-dispose, so this widget is the only place the
/// shell decides it. While the wrapped view is mounted the socket is up;
/// when the route pops, the watch goes with it and the socket closes.
///
/// Background is push only, so a pause closes the socket immediately
/// rather than waiting for a frame: a paused app may not draw another
/// one, and by then the OS is already holding a connection the phone is
/// not watching. Disposing the binding also latches the client, so no
/// backoff timer can redial while the app is away. A resume rebuilds a
/// fresh binding, which is safe because a resumed app does draw frames.
class RealtimeScope extends ConsumerStatefulWidget {
  final Widget child;

  const RealtimeScope({super.key, required this.child});

  @override
  ConsumerState<RealtimeScope> createState() => _RealtimeScopeState();
}

class _RealtimeScopeState extends ConsumerState<RealtimeScope>
    with WidgetsBindingObserver {
  /// The live binding, kept so a pause can close it without a frame.
  /// Null means the app is in the background.
  RealtimeBinding? _binding;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      final RealtimeBinding? binding = _binding;
      _binding = null;
      binding?.dispose();
      return;
    }
    // A resume that follows a pause needs a fresh binding. A resume with
    // no pause behind it is a no-op, so a lifecycle event the app never
    // asked for cannot churn the socket.
    if (state == AppLifecycleState.resumed && _binding == null) {
      ref.invalidate(realtimeBindingProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final RealtimeBinding binding = ref.watch(realtimeBindingProvider);
    _binding = binding;
    return widget.child;
  }
}

/// What a cold start learns from the SQLite cache before any network
/// call: whether a cached snapshot exists and how many device rows it
/// holds. The rows themselves belong to the snapshot source, so the gate
/// carries a count instead of a second copy of them.
class CacheProbe {
  final int deviceRows;

  const CacheProbe(this.deviceRows);

  const CacheProbe.empty() : deviceRows = 0;

  bool get isEmpty => deviceRows <= 0;
}

/// Reads the last foreground snapshot. The merge step overrides
/// [coldStartSourceProvider] with the SQLite backed reader; the default
/// boots with no cache, which is the honest state for a phone that has
/// never run in the foreground.
abstract class ColdStartSource {
  Future<CacheProbe> readCache();
}

/// Cache-free reader used until the merge step overrides the provider.
class EmptyColdStartSource implements ColdStartSource {
  const EmptyColdStartSource();

  @override
  Future<CacheProbe> readCache() async {
    return const CacheProbe.empty();
  }
}

final coldStartSourceProvider = Provider<ColdStartSource>(
  (Ref ref) => const EmptyColdStartSource(),
);

/// Which frame the shell is painting on a cold start.
enum BootPhase {
  /// Nothing painted yet, the cache read has not landed.
  cold,

  /// Cached frame up, live refresh in flight.
  cacheFirst,

  /// The live refresh landed. The cached frame is done.
  live,

  /// The live refresh failed. The cached frame stays with an error line
  /// instead of blanking, because a dropped network must not read as an
  /// empty phone.
  liveStale,
}

class ColdStartState {
  final BootPhase phase;

  /// Rows the cache read reported, shown on the cached frame only.
  final int deviceRows;

  const ColdStartState({
    this.phase = BootPhase.cold,
    this.deviceRows = 0,
  });
}

/// Runs the cold start in order: cache read first, then one live
/// refresh. The order is the whole point of the phase, so the two steps
/// live here rather than in a screen that could interleave them.
class ColdStartController extends StateNotifier<ColdStartState> {
  ColdStartController(this._ref) : super(const ColdStartState());

  final Ref _ref;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> boot() async {
    final ColdStartSource source = _ref.read(coldStartSourceProvider);
    final CacheProbe probe = await source.readCache();
    if (_disposed) {
      return;
    }
    if (!probe.isEmpty) {
      state = ColdStartState(
        phase: BootPhase.cacheFirst,
        deviceRows: probe.deviceRows,
      );
    }
    final DevicesController devices =
        _ref.read(devicesControllerProvider.notifier);
    await devices.refresh();
    if (_disposed) {
      return;
    }
    // The refresh reports failure through the devices state, not a return
    // value, and the raw error string never reaches the screen: PLAN
    // bans error strings from user facing telemetry.
    final String error = _ref.read(devicesControllerProvider).error;
    state = ColdStartState(
      phase: error.isEmpty ? BootPhase.live : BootPhase.liveStale,
      deviceRows: probe.deviceRows,
    );
  }
}

final coldStartProvider =
    StateNotifierProvider<ColdStartController, ColdStartState>(
  (Ref ref) => ColdStartController(ref),
);

/// Cold start gate: paints the cached frame, then the live one.
///
/// The gate owns the phase and nothing else. The rows come from the
/// snapshot source the merge step provides, so there is no second list
/// here to disagree with the live one.
class ColdStartGate extends ConsumerStatefulWidget {
  final Widget child;

  const ColdStartGate({super.key, required this.child});

  @override
  ConsumerState<ColdStartGate> createState() => _ColdStartGateState();
}

class _ColdStartGateState extends ConsumerState<ColdStartGate> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(coldStartProvider.notifier).boot());
  }

  @override
  Widget build(BuildContext context) {
    final ColdStartState boot = ref.watch(coldStartProvider);
    switch (boot.phase) {
      case BootPhase.cold:
        return const Center(
          key: ValueKey('cold-start-booting'),
          child: CircularProgressIndicator(),
        );
      case BootPhase.cacheFirst:
        return _framed(context, boot);
      case BootPhase.liveStale:
        return _framed(context, boot);
      case BootPhase.live:
        return widget.child;
    }
  }

  Widget _framed(BuildContext context, ColdStartState boot) {
    final bool failed = boot.phase == BootPhase.liveStale;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Column(
      children: <Widget>[
        Expanded(child: widget.child),
        Material(
          key: ValueKey(
            failed ? 'cold-start-refresh-failed' : 'cold-start-cache-strip',
          ),
          color: failed
              ? colors.errorContainer
              : colors.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: <Widget>[
                if (!failed) ...<Widget>[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    failed
                        ? 'Could not refresh. Showing the last known list.'
                        : 'Restoring ${boot.deviceRows} cached devices',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
