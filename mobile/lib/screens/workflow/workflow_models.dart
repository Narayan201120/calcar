import 'package:calcar/screens/workflow/chat_tab.dart';
import 'package:calcar/screens/workflow/files_tab.dart';

/// Constructor-fed view models for the workflow screens. No providers,
/// no client calls. Lists arrive fully formed from the caller.
class ActivityEntry {
  final String id;
  final String kind;
  final String text;
  final int atMillis;

  const ActivityEntry({
    required this.id,
    required this.kind,
    required this.text,
    required this.atMillis,
  });
}

/// One approval awaiting, or having received, a decision. A null
/// [resolution] means still pending. Expiry is derived from
/// [expiresAtMillis] against the clock the screen is given.
class ApprovalRequest {
  final String approvalId;
  final String title;
  final String detail;
  final int expiresAtMillis;
  final String? resolution;
  final bool destructive;

  const ApprovalRequest({
    required this.approvalId,
    required this.title,
    required this.detail,
    required this.expiresAtMillis,
    this.resolution,
    this.destructive = false,
  });
}

/// Whole workflow snapshot handed to [WorkflowScreen] through its
/// constructor. Caps are enforced upstream; counts record the true totals
/// so tails can announce truncation.
class WorkflowDetail {
  final String workflowId;
  final String title;
  final String status;
  final List<ActivityEntry> activity;
  final List<ApprovalRequest> approvals;
  final List<ChatMessage> messages;
  final List<String> terminalLines;
  final int terminalTotalLines;
  final int terminalPage;
  final int terminalTotalPages;
  final List<FileHunk> files;
  final bool filesTruncated;

  const WorkflowDetail({
    required this.workflowId,
    required this.title,
    required this.status,
    this.activity = const <ActivityEntry>[],
    this.approvals = const <ApprovalRequest>[],
    this.messages = const <ChatMessage>[],
    this.terminalLines = const <String>[],
    this.terminalTotalLines = 0,
    this.terminalPage = 1,
    this.terminalTotalPages = 1,
    this.files = const <FileHunk>[],
    this.filesTruncated = false,
  });
}
