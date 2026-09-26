// Authenticated channel to one managed computer over the private mesh
// (Tailscale or WireGuard). The P3 backend brokers identity and presence
// only, so workflow snapshots go straight to the agent, never through the
// backend. Same bearer token and X-Request-ID discipline as
// [CalcarApiClient], one class, no state.
//
// The endpoint set below is what the agent connection manager serves in
// P7. Until it lands, every call fails at the transport with a clear
// status, and the mobile gate never depends on a live agent.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../state/models.dart';

/// Stable error codes for the agent channel. Distinct from
/// `ApiCodes`: the agent is a different service with its own contract.
class AgentCodes {
  static const String revoked = 'REVOKED';
  static const String unauthorized = 'UNAUTHORIZED';
  static const String snapshotMissed = 'SNAPSHOT_MISSED';
  static const String workflowUnknown = 'WORKFLOW_UNKNOWN';
  static const String truncated = 'TRUNCATED';
  static const String truncatedNotice = 'TRUNCATED_NOTICE';
}

/// Failure from the agent channel. [code] is the agent's stable code, not
/// HTTP status; status is transport only.
class AgentException implements Exception {
  final int status;
  final String code;
  final String message;
  final bool retryable;

  const AgentException({
    required this.status,
    required this.code,
    required this.message,
    required this.retryable,
  });

  @override
  String toString() => 'AgentException($status, $code, $message)';
}

/// One snapshot method equals one logical fetch, matching the
/// [SnapshotSource] contract. Responses are defensive: missing optional
/// keys never crash a list, they drop the row.
class AgentChannelClient {
  final String baseUrl;
  final String token;
  final http.Client _http;

  AgentChannelClient({
    required String baseUrl,
    required this.token,
    http.Client? httpClient,
  })  : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _http = httpClient ?? http.Client();

  /// Dispose the underlying socket pool when the app backgrounds.
  void close() => _http.close();

  Map<String, String> _headers({String? requestId}) {
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
    if (requestId != null) {
      headers['X-Request-ID'] = requestId;
    }
    return headers;
  }

  Never _fail(int status) {
    throw AgentException(
      status: status,
      code: status == 401 ? AgentCodes.unauthorized : AgentCodes.snapshotMissed,
      message: 'agent channel unreachable: $status',
      retryable: status >= 500,
    );
  }

  T _decode<T>(http.Response res, T Function(Map<String, dynamic>) build) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _fail(res.statusCode);
    }
    return build(_decodeMap(res));
  }

  Map<String, dynamic> _decodeMap(http.Response res) {
    final Object? body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is! Map<String, dynamic>) {
      throw const AgentException(
        status: 500,
        code: 'MALFORMED',
        message: 'agent replied with a non-object body',
        retryable: false,
      );
    }
    return body;
  }

  /// GET /v1/agent/devices: the managed computers with workflow counts.
  List<WorkflowRow> fetchComputerRows(String userId) {
    final http.Response res = _http.get(
      _uri('/v1/agent/devices?user_id=$userId'),
      headers: _headers(),
    );
    return _decode(res, (Map<String, dynamic> j) {
      final Object? rows = j['workflows'];
      if (rows is! List) {
        return <WorkflowRow>[];
      }
      return rows
          .whereType<Map<String, dynamic>>()
          .map(
            (Map<String, dynamic> r) => WorkflowRow(
              workflowId: (r['workflow_id'] ?? '').toString(),
              computerId: (r['computer_id'] ?? '').toString(),
              title: (r['title'] ?? '').toString(),
              status: (r['status'] ?? '').toString(),
            ),
          )
          .toList();
    });
  }

  /// GET /v1/agent/computers/{id}: header plus sysinfo on demand.
  ComputerSnapshot fetchComputer(String computerId) {
    final http.Response res = _http.get(
      _uri('/v1/agent/computers/$computerId'),
      headers: _headers(),
    );
    return _decode(res, (Map<String, dynamic> j) {
      final Object? raw = j['workflows'];
      final List<Map<String, dynamic>> rows = raw is List
          ? raw.whereType<Map<String, dynamic>>().toList()
          : <Map<String, dynamic>>[];
      return ComputerSnapshot(
        deviceId: (j['device_id'] ?? computerId).toString(),
        displayName: (j['display_name'] ?? '').toString(),
        online: j['online'] == true,
        lastSeenMillis: (j['last_seen_millis'] as num?)?.toInt() ?? 0,
        workflows: rows
            .map(
              (Map<String, dynamic> r) => WorkflowRow(
                workflowId: (r['workflow_id'] ?? '').toString(),
                computerId: (r['computer_id'] ?? '').toString(),
              title: (r['title'] ?? '').toString(),
              status: (r['status'] ?? '').toString(),
            ),
          )
            .toList(),
      );
    });
  }

  /// GET /v1/agent/computers/{id}/sysinfo: CPU, RAM, GPU, disk. Lazy.
  Map<String, dynamic> fetchSysinfo(String computerId) {
    final http.Response res = _http.get(
      _uri('/v1/agent/computers/$computerId/sysinfo'),
      headers: _headers(),
    );
    return _decode(res, (Map<String, dynamic> j) => j);
  }

  /// GET /v1/agent/workflows/{id}: full capped buffers plus a
  /// last_seq_no high-water mark the state layer drops stale deltas
  /// against.
  WorkflowBuffers fetchWorkflow(String computerId, String workflowId) {
    final http.Response res = _http.get(
      _uri('/v1/agent/computers/$computerId/workflows/$workflowId'),
      headers: _headers(),
    );
    return _decode(res, (Map<String, dynamic> j) => _buffersFrom(j));
  }

  /// POST /v1/agent/approvals/{id}: resolve one approval. Idempotency
  /// key required: a retried send after a 60 second drop must apply at
  /// most once, so the key is caller-supplied and stable per resolve.
  void postApprovalResolve({
    required String workflowId,
    required String requestId,
    required bool allow,
  }) {
    final http.Response res = _http.post(
      _uri('/v1/agent/workflows/$workflowId/approvals'),
      headers: _headers(requestId: requestId),
    body: jsonEncode(<String, dynamic>{
      'approval_id': requestId,
      'allow': allow,
    });
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _fail(res.statusCode);
    }
  }

  /// POST /v1/agent/workflows/{id}/inputs: one input with a client-side
  /// UUID, so a retry after a drop duplicates nothing.
  void postInput({
    required String workflowId,
    required String inputId,
    required String body,
    required bool destructive,
  }) {
    final http.Response res = _http.post(
      _uri('/v1/agent/workflows/$workflowId/inputs'),
      headers: _headers(requestId: inputId),
    body: jsonEncode(<String, dynamic>{
      'input_id': inputId,
      'body': body,
      'destructive': destructive,
    });
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _fail(res.statusCode);
    }
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');
}

/// Parse one agent workflow snapshot body into the state layer's buffers.
/// Defensive by rule: a row missing its id is dropped, never faked. Caps
/// were already applied agent-side; the state layer re-caps on insert.
WorkflowBuffers _buffersFrom(Map<String, dynamic> j) {
  List<Map<String, dynamic>> rows(String key) {
    final Object? raw = j[key];
    return raw is List
        ? raw.whereType<Map<String, dynamic>>().toList()
        : <Map<String, dynamic>>[];
  }

  String str(String key) => (j[key] ?? '').toString();
  int num_(String key) => (j[key] as num?)?.toInt() ?? 0;

  final List<BufferedActivity> activity = <BufferedActivity>[];
  for (final Map<String, dynamic> r in rows('activity')) {
    final String id = (r['event_id'] ?? '').toString();
    if (id.isEmpty) {
      continue;
    }
    activity.add(
      BufferedActivity(
        id: id,
        kind: (r['event_type'] ?? '').toString(),
        text: (r['summary'] ?? '').toString(),
        atMillis: (r['occurred_at_millis'] as num?)?.toInt() ?? 0,
        seqNo: (r['seq_no'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  final List<BufferedChat> chat = <BufferedChat>[];
  for (final Map<String, dynamic> r in rows('chat')) {
    final String id = (r['message_id'] ?? '').toString();
    if (id.isEmpty) {
      continue;
    }
    chat.add(
      BufferedChat(
        messageId: id,
        body: (r['body'] ?? '').toString(),
        outbound: r['outbound'] == true,
        sendState: (r['send_state'] ?? 'sent').toString(),
        seqNo: (r['seq_no'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  final List<String> terminal = <String>[];
  for (final Object? line in (j['terminal_lines'] is List
      ? (j['terminal_lines'] as List)
      : <Object?>[])) {
    terminal.add(line.toString());
  }

  final List<BufferedFile> files = <BufferedFile>[];
  for (final Map<String, dynamic> r in rows('files')) {
    final String path = (r['path'] ?? '').toString();
    if (path.isEmpty) {
      continue;
    }
    files.add(
      BufferedFile(
        path: path,
        diff: (r['diff'] ?? '').toString(),
        truncated: r['truncated'] == true,
      ),
    );
  }

  final List<TrackedApproval> approvals = <TrackedApproval>[];
  for (final Map<String, dynamic> r in rows('approvals')) {
    final String id = (r['approval_id'] ?? '').toString();
    if (id.isEmpty) {
      continue;
    }
    final Object? resolution = r['resolution'];
    approvals.add(
      TrackedApproval(
        approvalId: id,
        workflowId: str('workflow_id'),
        title: (r['title'] ?? '').toString(),
        detail: (r['detail'] ?? '').toString(),
        expiresAtMillis:
            (r['expires_at_millis'] as num?)?.toInt() ?? 0,
        resolution: resolution == null ? null : resolution.toString(),
        destructive: r['destructive'] == true,
      ),
    );
  }

  return WorkflowBuffers(
    workflowId: str('workflow_id'),
    computerId: str('computer_id'),
    status: (j['status'] ?? 'running').toString(),
    lastSeqNo: num_('last_seq_no'),
    activity: activity,
    chat: chat,
    terminalLines: terminal,
    terminalTotalLines: num_('terminal_total_lines'),
    files: files,
    filesTruncated: j['files_truncated'] == true,
    approvals: approvals,
  );
}
