// Single-use pairing session state for Add Computer.
//
// One session per flow, walking forward only. A decision consumes the
// session, the TTL expires it, and neither can be reused: regenerate
// mints a brand new session id, so a spent session is never replayed.
//
// The join pubkey is the one field the control plane does not hand back.
// The session record carries the name, fingerprint, and request id, but
// the backend refuses a decision whose subject pubkey differs from the
// stored join, so the pubkey can only come from the socket's join event.
// An approve without it is refused with a reason instead of sent with a
// guess.
import 'dart:async';

import 'package:calcar/api/api_error.dart';
import 'package:calcar/api/client.dart';
import 'package:calcar/api/models.dart';
import 'package:calcar/screens/add_computer.dart';
import 'package:calcar/screens/wired/wired_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Backend session statuses this flow reacts to. Anything else is a live
/// session the Owner still owns.
const String _statusExpired = 'expired';
const String _statusConsumed = 'consumed';
const String _statusApproved = 'approved';
const String _statusRejected = 'rejected';

/// How often the phone re-reads the session while the QR is up. The
/// socket also signals a join; the poll covers the window where the phone
/// was foregrounded and that signal never arrived.
const Duration kPairingPollInterval = Duration(seconds: 2);

/// Owner-signed fields only the hardware keystore can produce.
class PairingAuthorization {
  final String signatureB64;
  final String authorizationId;
  final String nonceB64;
  final int decidedAtMillis;

  const PairingAuthorization({
    required this.signatureB64,
    required this.authorizationId,
    required this.nonceB64,
    required this.decidedAtMillis,
  });
}

/// What the Owner is shown, and what the decision must be bound to.
class PairingJoin {
  final String requestId;
  final String pubkeyB64;
  final String displayName;
  final String fingerprint;

  const PairingJoin({
    required this.requestId,
    required this.pubkeyB64,
    required this.displayName,
    required this.fingerprint,
  });
}

/// Hardware-backed signer. Returns the fields bound to this exact join.
typedef PairingSigner = Future<PairingAuthorization> Function(
  PairingJoin join,
);

/// One flow per id, dropped when the last viewer navigates away, so the
/// next entry starts a brand new session. Two ids never share an
/// idempotency namespace.
final addComputerControllerProvider = StateNotifierProvider.autoDispose
    .family<AddComputerController, AddComputerState, String>(
  (Ref ref, String flowId) {
    return AddComputerController(
      ref.watch(apiClientProvider),
      namespace: flowId,
    );
  },
);

class AddComputerState {
  final AddComputerStage stage;

  /// Backend session id, present from the QR stage on.
  final String sessionId;

  /// Session reference carried by the QR. A QR is never trust.
  final String qrNonce;

  /// TTL deadline, checked against the caller's clock.
  final int expiresAtMillis;

  /// The join request under decision, once one has landed.
  final PairingJoin? join;

  /// Device id the backend minted for the approved computer.
  final String subjectDeviceId;

  /// True while a control-plane call is in flight. A decision already has
  /// a progress stage of its own; creation and regenerate do not, so
  /// their buttons go inert instead.
  final bool busy;

  /// Last failure, surfaced by the screen. It never blocks a stage: the
  /// Owner decides whether to retry.
  final String error;

  const AddComputerState({
    required this.stage,
    this.sessionId = '',
    this.qrNonce = '',
    this.expiresAtMillis = 0,
    this.join,
    this.subjectDeviceId = '',
    this.busy = false,
    this.error = '',
  });

  factory AddComputerState.initial() {
    return const AddComputerState(stage: AddComputerStage.create);
  }

  AddComputerState copyWith({
    AddComputerStage? stage,
    String? sessionId,
    String? qrNonce,
    int? expiresAtMillis,
    PairingJoin? join,
    String? subjectDeviceId,
    bool? busy,
    String? error,
  }) {
    return AddComputerState(
      stage: stage ?? this.stage,
      sessionId: sessionId ?? this.sessionId,
      qrNonce: qrNonce ?? this.qrNonce,
      expiresAtMillis: expiresAtMillis ?? this.expiresAtMillis,
      join: join ?? this.join,
      subjectDeviceId: subjectDeviceId ?? this.subjectDeviceId,
      busy: busy ?? this.busy,
      error: error ?? this.error,
    );
  }

  /// True once the session is spent or gone. Nothing transitions back out
  /// of these, which is what makes the session single use.
  bool get isTerminal {
    return stage == AddComputerStage.done ||
        stage == AddComputerStage.expired;
  }

  /// True while a decision is in flight. The pure screen renders these as
  /// inert progress states.
  bool get deciding {
    return stage == AddComputerStage.approving ||
        stage == AddComputerStage.rejecting;
  }
}

class AddComputerController extends StateNotifier<AddComputerState> {
  AddComputerController(this._api, {required String namespace})
      : _namespace = namespace,
        super(AddComputerState.initial());

  final CalcarApiClient _api;
  final String _namespace;
  Timer? _poll;
  int _attempts = 0;
  bool _gone = false;

  @override
  void dispose() {
    _gone = true;
    _poll?.cancel();
    _poll = null;
    super.dispose();
  }

  /// Mints a session, from the create stage or from regenerate. A live
  /// session is never replaced mid flight, and every mint is a new id, so
  /// a spent session cannot come back.
  Future<void> createSession() async {
    if (state.busy || state.deciding) {
      return;
    }
    if (state.sessionId.isNotEmpty && !state.isTerminal) {
      return;
    }
    _stopPolling();
    _attempts += 1;
    _emit(
      () => const AddComputerState(
        stage: AddComputerStage.create,
        busy: true,
      ),
    );
    try {
      final PairingSession session =
          await _api.createPairingSession(_requestId('create', _attempts));
      _emit(
        () => state.copyWith(
          stage: AddComputerStage.qr,
          sessionId: session.sessionId,
          qrNonce: session.qrNonce,
          expiresAtMillis: session.expiresAtMillis,
          busy: false,
        ),
      );
      _startPolling();
    } on Object catch (error) {
      _emit(() => state.copyWith(busy: false, error: '$error'));
    }
  }

  /// Records the join as the socket reported it, pubkey included. The poll
  /// fills in the same join without the pubkey, so this only ever
  /// completes what the control plane cannot.
  void applyJoin(PairingJoin join) {
    if (state.sessionId.isEmpty || state.isTerminal) {
      return;
    }
    _emit(() => state.copyWith(stage: AddComputerStage.waiting, join: join));
  }

  /// Approve or reject the waiting join, once. The request id is stable
  /// per session and decision, so a retry after a dropped response is the
  /// same request rather than a second decision.
  Future<void> decide({
    required bool approve,
    required PairingSigner? signer,
  }) async {
    final String sessionId = state.sessionId;
    final PairingJoin? join = state.join;
    if (sessionId.isEmpty ||
        join == null ||
        state.deciding ||
        state.isTerminal) {
      return;
    }
    if (approve && (signer == null || join.pubkeyB64.isEmpty)) {
      _emit(
        () => state.copyWith(
          error: 'Cannot approve: the join public key never arrived. '
              'Scan again with the phone online.',
        ),
      );
      return;
    }
    _emit(
      () => state.copyWith(
        stage: approve ? AddComputerStage.approving : AddComputerStage.rejecting,
        error: '',
      ),
    );
    try {
      PairingAuthorization? authorization;
      if (approve) {
        authorization = await signer!(join);
      }
      final PairingDecisionResult result = await _api.decidePairingSession(
        sessionId,
        _requestId(approve ? 'approve' : 'reject', 0),
        approve: approve,
        subjectPubkeyB64: join.pubkeyB64,
        signatureB64: authorization?.signatureB64 ?? '',
        authorizationId: authorization?.authorizationId ?? '',
        nonceB64: authorization?.nonceB64 ?? '',
        decidedAtMillis: authorization?.decidedAtMillis ?? 0,
      );
      _stopPolling();
      _emit(
        () => state.copyWith(
          stage: AddComputerStage.done,
          subjectDeviceId: result.subjectDeviceId ?? '',
        ),
      );
    } on Object catch (error) {
      _failDecision(error);
    }
  }

  /// TTL check against the caller's clock. The session record also reports
  /// expiry, and both paths converge on the same dead stage.
  void tick(int nowMillis) {
    if (state.isTerminal || state.expiresAtMillis == 0) {
      return;
    }
    if (state.expiresAtMillis > nowMillis) {
      return;
    }
    _stopPolling();
    _emit(() => state.copyWith(stage: AddComputerStage.expired));
  }

  /// A decision that failed for any reason other than a spent or missing
  /// session leaves the session live, so the Owner can decide again from
  /// the same card. A spent session is done, not expired: the first
  /// outcome stands and re-deciding it is refused.
  void _failDecision(Object error) {
    _stopPolling();
    final String code = error is ApiException ? error.code : '';
    if (code == ApiCodes.pairingConsumed) {
      _emit(
        () => state.copyWith(
          stage: AddComputerStage.done,
          error: 'Already decided, the earlier outcome stands',
        ),
      );
      return;
    }
    if (code == ApiCodes.pairingExpired || code == ApiCodes.unknownSession) {
      _emit(
        () => state.copyWith(
          stage: AddComputerStage.expired,
          error: '$error',
        ),
      );
      return;
    }
    _emit(
      () => state.copyWith(
        stage: AddComputerStage.waiting,
        error: '$error',
      ),
    );
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(kPairingPollInterval, (Timer _) {
      unawaited(readSession());
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// One read of the session record while a session is live.
  Future<void> readSession() async {
    final String sessionId = state.sessionId;
    if (sessionId.isEmpty || state.isTerminal || state.deciding) {
      return;
    }
    try {
      _applySession(await _api.getPairingSession(sessionId));
    } on Object catch (error) {
      final String code = error is ApiException ? error.code : '';
      if (code == ApiCodes.pairingExpired ||
          code == ApiCodes.unknownSession) {
        _stopPolling();
        _emit(
          () => state.copyWith(
            stage: AddComputerStage.expired,
            error: '$error',
          ),
        );
      }
    }
  }

  void _applySession(PairingSession session) {
    if (session.status == _statusExpired) {
      _stopPolling();
      _emit(() => state.copyWith(stage: AddComputerStage.expired));
      return;
    }
    if (session.status == _statusConsumed ||
        session.status == _statusApproved ||
        session.status == _statusRejected) {
      _stopPolling();
      _emit(() => state.copyWith(stage: AddComputerStage.done));
      return;
    }
    final String requestId = session.joinRequestId ?? '';
    if (requestId.isEmpty) {
      return;
    }
    // Keep a pubkey the socket already supplied for this same join.
    final PairingJoin? known = state.join;
    _emit(
      () => state.copyWith(
        stage: AddComputerStage.waiting,
        join: PairingJoin(
          requestId: requestId,
          pubkeyB64: known != null && known.requestId == requestId
              ? known.pubkeyB64
              : '',
          displayName: session.joinDisplayName ?? '',
          fingerprint: session.joinFingerprint ?? '',
        ),
      ),
    );
  }

  /// Client-side idempotency key. Namespaced per flow and stamped with the
  /// wall clock, so a restart never replays a spent request id.
  String _requestId(String step, int attempt) {
    final int millis = DateTime.now().millisecondsSinceEpoch;
    return '$_namespace-$step-$attempt-$millis';
  }

  /// Publishes the next stage, unless the flow already closed. The next
  /// state is built lazily because reading [state] after dispose throws,
  /// and a call that lands after the screen closed has nobody to report
  /// to anyway.
  void _emit(AddComputerState Function() build) {
    if (_gone) {
      return;
    }
    state = build();
  }
}
