/// Push wiring for the P6 thin client: register the FCM and APNs token
/// with the control plane, and turn a notification tap into a deep link.
///
/// Privacy contract (PLAN P3): the push body carries ids and kind only.
/// Full detail is fetched over the authenticated channel before the
/// shell navigates, so the tap paints from data the backend chose to
/// send over an authenticated channel, never from the body.
///
/// Nothing from the body or the token reaches a log field. That is a
/// type decision, not a discipline one: [PushLogEntry] holds enums only,
/// so a call site has nowhere to put an id, a token, or a payload. The
/// backend error code is not logged either, because the `error` field is
/// a free string from the wire and PLAN bans error strings from
/// telemetry. [PushStatus] buckets it instead.
library;

import 'package:calcar/api/api.dart';
import 'package:calcar/app.dart';
import 'package:calcar/state/state.dart';
import 'package:flutter/foundation.dart';

/// Where a line goes. Defaults to [debugPrint]; production may pass a
/// structured sink. Lines carry no payload content either way.
typedef PushLogSink = void Function(String line);

void _consoleLine(String line) {
  debugPrint(line);
}

/// Push platforms the phone registers a token for. FCM on Android, APNs
/// on iOS. [wire] is the value the backend stores as `platform`.
enum PushPlatform {
  fcm('fcm'),
  apns('apns');

  const PushPlatform(this.wire);

  final String wire;
}

/// Attention kinds the phone routes.
///
/// The ids pick the screen; the kind only refines it. Every kind the
/// backend may add folds into [other] instead of being dropped, because
/// the contract is additive only and a notification that routes is worth
/// more than a notification that parses.
enum PushKind {
  /// A pending approval. Routes to the approval when the body carries an
  /// approval id, otherwise to the workflow.
  approvalRequired,

  /// A workflow is waiting for input. Routes to the workflow.
  inputRequired,

  completed,
  failed,
  error,

  /// Any kind this build does not know.
  other;

  /// Maps a wire kind onto the closed set. The raw string never leaves
  /// this function, so an unrecognised kind cannot reach a log or a
  /// route as free text.
  static PushKind fromWire(String raw) {
    switch (raw) {
      case 'approval_required':
        return PushKind.approvalRequired;
      case 'input_required':
        return PushKind.inputRequired;
      case 'completed':
        return PushKind.completed;
      case 'failed':
        return PushKind.failed;
      case 'error':
        return PushKind.error;
      default:
        return PushKind.other;
    }
  }
}

/// Why a call failed, in a closed set. Never the backend error string.
enum PushStatus {
  /// 401. The session or the token registration is not authenticated.
  unauthorized,

  /// 403. Authenticated, not allowed.
  forbidden,

  /// 404 or 410. The device, session, or target is gone.
  gone,

  /// Another 4xx.
  clientError,

  /// 5xx.
  serverError,

  /// The call never completed, or the failure is not an API error.
  transport;

  static PushStatus classify(Object error) {
    if (error is ApiException) {
      if (error.status == 401) {
        return PushStatus.unauthorized;
      }
      if (error.status == 403) {
        return PushStatus.forbidden;
      }
      if (error.status == 404 || error.status == 410) {
        return PushStatus.gone;
      }
      if (error.status >= 500) {
        return PushStatus.serverError;
      }
      if (error.status >= 400) {
        return PushStatus.clientError;
      }
    }
    return PushStatus.transport;
  }
}

/// What happened, with nothing that could carry content.
enum PushLogEvent {
  /// A token was accepted by the control plane.
  tokenRegistered,

  /// A token post failed. The token is not logged and is retried on the
  /// next register.
  tokenRegistrationFailed,

  /// A notification body carried no usable ids, so nothing was opened.
  notificationIgnored,

  /// The full detail behind a tap could not be fetched, so nothing was
  /// opened.
  detailFetchFailed,

  /// A tap fetched its detail and the shell was told to open the link.
  deepLinkOpened,
}

/// One log line. Every field is an enum, so no id, token, payload, or
/// server string can be attached to it.
class PushLogEntry {
  final PushLogEvent event;
  final PushPlatform? platform;
  final PushKind? kind;
  final PushStatus? status;

  const PushLogEntry({
    required this.event,
    this.platform,
    this.kind,
    this.status,
  });

  String format() {
    final StringBuffer line = StringBuffer('calcar.push ${event.name}');
    if (platform != null) {
      line.write(' platform=${platform!.wire}');
    }
    if (kind != null) {
      line.write(' kind=${kind!.name}');
    }
    if (status != null) {
      line.write(' status=${status!.name}');
    }
    return line.toString();
  }
}

/// One notification body, reduced to ids plus kind.
///
/// [tryParse] reads four keys and drops everything else, so a body that
/// also carries source, prompts, or terminal output cannot smuggle it
/// into navigation state. A body with no computer id is not routable at
/// all and parses to null.
class PushPayload {
  final PushKind kind;
  final String computerId;
  final String workflowId;
  final String approvalId;

  const PushPayload({
    required this.kind,
    required this.computerId,
    this.workflowId = '',
    this.approvalId = '',
  });

  static PushPayload? tryParse(Map<String, dynamic> data) {
    final Object? rawComputer = data['computer_id'];
    if (rawComputer is! String || rawComputer.isEmpty) {
      return null;
    }
    final Object? rawKind = data['kind'];
    return PushPayload(
      kind: PushKind.fromWire(rawKind is String ? rawKind : ''),
      computerId: rawComputer,
      workflowId: _idOf(data['workflow_id']),
      approvalId: _idOf(data['approval_id']),
    );
  }

  static String _idOf(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      return raw;
    }
    return '';
  }

  /// The screen these ids address. A workflow id is what makes a link
  /// address a workflow, and an approval id on an approval payload is
  /// what makes it address the approval, so a body that carries only the
  /// two ids the backend sends today still routes to the workflow.
  DeepLink get link {
    if (workflowId.isEmpty) {
      return DeepLink(kind: DeepLinkKind.computer, computerId: computerId);
    }
    if (kind == PushKind.approvalRequired && approvalId.isNotEmpty) {
      return DeepLink(
        kind: DeepLinkKind.approval,
        computerId: computerId,
        workflowId: workflowId,
        approvalId: approvalId,
      );
    }
    return DeepLink(
      kind: DeepLinkKind.workflow,
      computerId: computerId,
      workflowId: workflowId,
    );
  }
}

/// One platform push token.
///
/// The implementation is the merge step's job: this file holds no
/// firebase or APNs plugin wiring and calls no platform channel, so a
/// test drives a fake with canned tokens and nothing else.
abstract class PushTokenSource {
  PushPlatform get platform;

  /// The token the platform currently holds, or null while it has not
  /// issued one yet.
  Future<String?> readToken();
}

/// Registers push tokens and routes notification taps.
///
/// Register is idempotent per platform: a token that has not changed
/// posts once and never again, so a foreground resume or a rebuild cannot
/// spam the control plane. A rotated token posts again because the old
/// one is dead.
class PushService {
  PushService({
    required this.api,
    required this.source,
    required this.bus,
    required this.deviceId,
    this.tokenSources = const <PushTokenSource>[],
    PushLogSink? log,
    String Function()? requestId,
  })  : _log = log ?? _consoleLine,
        _requestId = requestId ?? newRequestId;

  /// Control plane client, already carrying the bearer token.
  final CalcarApiClient api;

  /// Authed channel the full detail comes from. Same seam the state
  /// layer uses, so a tap and a screen read the same snapshot.
  final SnapshotSource source;

  /// Where a resolved tap is published for [CalcarApp].
  final DeepLinkBus bus;

  /// Device id the token belongs to. The control plane stores one token
  /// per device and platform.
  final String deviceId;

  /// One source per platform the build supports.
  final List<PushTokenSource> tokenSources;

  final PushLogSink _log;
  final String Function() _requestId;

  /// Last token accepted per platform, so a repeat register is a no-op.
  final Map<PushPlatform, String> _accepted = <PushPlatform, String>{};

  /// Posts a token for every source that holds one. Returns how many
  /// posts were made, so a caller can tell a first register from a
  /// resume that had nothing new to say.
  Future<int> register() async {
    int posts = 0;
    for (final PushTokenSource tokens in tokenSources) {
      final PushPlatform platform = tokens.platform;
      final String? token = await tokens.readToken();
      if (token == null || token.isEmpty) {
        continue;
      }
      if (_accepted[platform] == token) {
        continue;
      }
      try {
        await api.postPushToken(
          deviceId,
          _requestId(),
          platform: platform.wire,
          pushToken: token,
        );
        _accepted[platform] = token;
        posts += 1;
        _log(
          PushLogEntry(
            event: PushLogEvent.tokenRegistered,
            platform: platform,
          ).format(),
        );
      } on Object catch (error) {
        _log(
          PushLogEntry(
            event: PushLogEvent.tokenRegistrationFailed,
            platform: platform,
            status: PushStatus.classify(error),
          ).format(),
        );
      }
    }
    return posts;
  }

  /// Handles one notification tap.
  ///
  /// Parses the body, fetches the full detail over the authenticated
  /// channel, then publishes the link for the shell. Returns the request
  /// it published, or null when the body carried no usable ids or the
  /// detail fetch failed. Nothing is opened in either failure case: a
  /// tap with nothing to show must not land on a half built screen.
  Future<DeepLinkRequest?> onNotificationOpened(
    Map<String, dynamic> data,
  ) async {
    final PushPayload? payload = PushPayload.tryParse(data);
    if (payload == null) {
      _log(
        const PushLogEntry(
          event: PushLogEvent.notificationIgnored,
        ).format(),
      );
      return null;
    }
    final DeepLink link = payload.link;
    try {
      final DeepLinkDetail detail = await _fetchDetail(link);
      _log(
        PushLogEntry(
          event: PushLogEvent.deepLinkOpened,
          kind: payload.kind,
        ).format(),
      );
      final DeepLinkRequest request = DeepLinkRequest(
        link: link,
        detail: detail,
      );
      bus.open(request);
      return request;
    } on Object catch (error) {
      _log(
        PushLogEntry(
          event: PushLogEvent.detailFetchFailed,
          kind: payload.kind,
          status: PushStatus.classify(error),
        ).format(),
      );
      return null;
    }
  }

  Future<DeepLinkDetail> _fetchDetail(DeepLink link) async {
    if (link.kind == DeepLinkKind.computer) {
      final ComputerSnapshot snapshot = await source.fetchComputer(
        link.computerId,
      );
      return ComputerSnapshotDetail(snapshot);
    }
    final WorkflowBuffers buffers = await source.fetchWorkflow(
      link.computerId,
      link.workflowId,
    );
    return WorkflowBuffersDetail(buffers);
  }
}
