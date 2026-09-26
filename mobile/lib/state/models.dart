// Snapshot-first state models for the P6 thin client.
//
// These are the shapes the merge step hands to screens: device rows with
// presence, computer headers with workflow rows, and capped workflow
// buffers. Badges (Owner) and status chips are derived from this state
// by the pure helpers below and never stored, so a stale label cannot
// outlive the data it describes. Chip text itself stays with
// [workflowStatusLabel] in screens/computer_detail.dart.
import 'dart:convert';

import 'package:calcar/api/models.dart';

import 'caps.dart';

/// One workflow row on a computer. [status] mirrors the agent lifecycle
/// strings (running, waiting_input, waiting_approval, completed, failed,
/// stopped); unknown states pass through to the chip label raw.
class WorkflowRow {
  final String workflowId;
  final String computerId;
  final String title;
  final String status;

  const WorkflowRow({
    required this.workflowId,
    required this.computerId,
    required this.title,
    required this.status,
  });
}

/// One managed computer header plus its workflow rows. Fetched as a
/// single snapshot; live presence and row deltas patch it after.
class ComputerSnapshot {
  final String deviceId;
  final String displayName;
  final bool online;
  final int lastSeenMillis;
  final List<WorkflowRow> workflows;

  const ComputerSnapshot({
    required this.deviceId,
    required this.displayName,
    required this.online,
    required this.lastSeenMillis,
    required this.workflows,
  });
}

/// One activity ring entry. [seqNo] is the per-workflow monotonic
/// sequence from the agent event stream, used to drop stale deltas.
class BufferedActivity {
  final String id;
  final String kind;
  final String text;
  final int atMillis;
  final int seqNo;

  const BufferedActivity({
    required this.id,
    required this.kind,
    required this.text,
    required this.atMillis,
    required this.seqNo,
  });
}

/// One chat message. [seqNo] orders live deltas against the snapshot
/// high-water mark; snapshot rows carry the snapshot seq.
class BufferedChat {
  final String messageId;
  final String body;
  final bool outbound;
  final String sendState;
  final int seqNo;

  const BufferedChat({
    required this.messageId,
    required this.body,
    this.outbound = false,
    this.sendState = 'sent',
    this.seqNo = 0,
  });
}

/// One capped file diff hunk. [truncated] marks a hunk cut by the caps.
class BufferedFile {
  final String path;
  final String diff;
  final bool truncated;

  const BufferedFile({
    required this.path,
    required this.diff,
    this.truncated = false,
  });
}

/// One approval tracked in a workflow. A null [resolution] means still
/// pending. Expiry is derived from [expiresAtMillis] against the clock
/// the caller passes, so widgets and tests pin the same instant.
class TrackedApproval {
  final String approvalId;
  final String workflowId;
  final String title;
  final String detail;
  final int expiresAtMillis;
  final String? resolution;
  final bool destructive;

  const TrackedApproval({
    required this.approvalId,
    required this.workflowId,
    required this.title,
    required this.detail,
    required this.expiresAtMillis,
    this.resolution,
    this.destructive = false,
  });

  bool get isResolved => resolution != null;

  bool isExpired(int nowMillis) =>
      !isResolved && expiresAtMillis <= nowMillis;

  bool isInert(int nowMillis) => isResolved || isExpired(nowMillis);

  bool canResolve(int nowMillis) => !isInert(nowMillis);

  TrackedApproval withResolution(String decision) {
    return TrackedApproval(
      approvalId: approvalId,
      workflowId: workflowId,
      title: title,
      detail: detail,
      expiresAtMillis: expiresAtMillis,
      resolution: decision,
      destructive: destructive,
    );
  }
}

/// Lookup key for the per-workflow provider family.
class WorkflowKey {
  final String computerId;
  final String workflowId;

  const WorkflowKey({required this.computerId, required this.workflowId});

  @override
  bool operator ==(Object other) =>
      other is WorkflowKey &&
      other.computerId == computerId &&
      other.workflowId == workflowId;

  @override
  int get hashCode => Object.hash(computerId, workflowId);
}

/// All buffered workflow detail for one workflow. [lastSeqNo] is the
/// high-water mark: deltas at or below it are stale and dropped.
/// [terminalTotalLines] tracks the true total so the terminal tab can
/// announce truncation; [filesTruncated] does the same for diffs.
class WorkflowBuffers {
  final String workflowId;
  final String computerId;
  final String status;
  final int lastSeqNo;
  final List<BufferedActivity> activity;
  final List<BufferedChat> chat;
  final List<String> terminalLines;
  final int terminalTotalLines;
  final List<BufferedFile> files;
  final bool filesTruncated;
  final List<TrackedApproval> approvals;

  const WorkflowBuffers({
    required this.workflowId,
    required this.computerId,
    required this.status,
    required this.lastSeqNo,
    this.activity = const <BufferedActivity>[],
    this.chat = const <BufferedChat>[],
    this.terminalLines = const <String>[],
    this.terminalTotalLines = 0,
    this.files = const <BufferedFile>[],
    this.filesTruncated = false,
    this.approvals = const <TrackedApproval>[],
  });

  factory WorkflowBuffers.empty({
    required String computerId,
    required String workflowId,
  }) {
    return WorkflowBuffers(
      workflowId: workflowId,
      computerId: computerId,
      status: 'running',
      lastSeqNo: 0,
    );
  }

  WorkflowBuffers copyWith({
    String? status,
    int? lastSeqNo,
    List<BufferedActivity>? activity,
    List<BufferedChat>? chat,
    List<String>? terminalLines,
    int? terminalTotalLines,
    List<BufferedFile>? files,
    bool? filesTruncated,
    List<TrackedApproval>? approvals,
  }) {
    return WorkflowBuffers(
      workflowId: workflowId,
      computerId: computerId,
      status: status ?? this.status,
      lastSeqNo: lastSeqNo ?? this.lastSeqNo,
      activity: activity ?? this.activity,
      chat: chat ?? this.chat,
      terminalLines: terminalLines ?? this.terminalLines,
      terminalTotalLines: terminalTotalLines ?? this.terminalTotalLines,
      files: files ?? this.files,
      filesTruncated: filesTruncated ?? this.filesTruncated,
      approvals: approvals ?? this.approvals,
    );
  }

  /// Enforces every cap defensively, for snapshots fetched before the
  /// agent learned them. Always returns unmodifiable lists.
  WorkflowBuffers capped() {
    return WorkflowBuffers(
      workflowId: workflowId,
      computerId: computerId,
      status: status,
      lastSeqNo: lastSeqNo,
      activity: tailOf<BufferedActivity>(activity, kActivityCap),
      chat: tailOf<BufferedChat>(chat, kChatCap),
      terminalLines: capTerminalTail(terminalLines),
      terminalTotalLines: terminalTotalLines,
      files: capDiffs(files),
      filesTruncated: filesTruncated,
      approvals: List<TrackedApproval>.unmodifiable(approvals),
    );
  }
}

/// Keeps the first [kDiffFileCap] hunks within [kDiffByteCap] total
/// bytes. The boundary hunk is cut on a rune edge and flagged, so a cut
/// diff never reads as complete. Always returns an unmodifiable list.
List<BufferedFile> capDiffs(List<BufferedFile> hunks) {
  final List<BufferedFile> out = <BufferedFile>[];
  int bytes = 0;
  final int total = hunks.length > kDiffFileCap ? kDiffFileCap : hunks.length;
  for (int i = 0; i < total; i++) {
    final BufferedFile hunk = hunks[i];
    final int size = utf8.encode(hunk.diff).length;
    if (bytes + size > kDiffByteCap) {
      final int room = kDiffByteCap - bytes;
      out.add(
        BufferedFile(
          path: hunk.path,
          diff: room > 0
              ? '${headBytes(hunk.diff, room)}...truncated'
              : '...truncated',
          truncated: true,
        ),
      );
      break;
    }
    bytes += size;
    out.add(hunk);
  }
  return List<BufferedFile>.unmodifiable(out);
}

/// True when the kept hunks do not cover the incoming total, or any
/// kept hunk was cut. Drives the files truncation notice.
bool diffsTruncated(List<BufferedFile> kept, int incomingTotal) {
  if (incomingTotal > kept.length) {
    return true;
  }
  return kept.any((BufferedFile hunk) => hunk.truncated);
}

/// Cuts [text] to at most [maxBytes] UTF-8 bytes on a rune edge.
String headBytes(String text, int maxBytes) {
  int bytes = 0;
  int end = 0;
  for (final int rune in text.runes) {
    final int size =
        rune < 128 ? 1 : utf8.encode(String.fromCharCode(rune)).length;
    if (bytes + size > maxBytes) {
      break;
    }
    bytes += size;
    end += rune > 0xFFFF ? 2 : 1;
  }
  return text.substring(0, end);
}

/// True for the Owner phone: id match wins, then the owner roles.
/// A superset of the screen check on purpose, so the state-level
/// revoke guard can never miss an owner row.
bool isOwnerDevice(Device device, String ownerDeviceId) {
  if (ownerDeviceId.isNotEmpty && device.deviceId == ownerDeviceId) {
    return true;
  }
  final String role = device.role.toLowerCase();
  return role == 'owner' || role == 'owner_phone';
}

/// True for Owner and trusted phones, false for managed computers.
bool isPhoneDevice(Device device) {
  final String role = device.role.toLowerCase();
  return role.contains('phone') || role == 'owner';
}

/// Derived online state for one device row. Revoked wins over presence,
/// missing presence reads as never seen (offline).
String deviceStateOf(Device device, Map<String, Presence> presenceById) {
  if (device.revoked) {
    return 'revoked';
  }
  final Presence? presence = presenceById[device.deviceId];
  if (presence != null && presence.online) {
    return 'online';
  }
  return 'offline';
}

/// The Owner badge is derived, and the Owner row is never revocable
/// here; revoked rows lose their button too.
bool isRevocable(Device device, String ownerDeviceId) {
  return !isOwnerDevice(device, ownerDeviceId) && !device.revoked;
}
