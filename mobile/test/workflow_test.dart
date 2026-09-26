import 'package:calcar/screens/workflow/chat_tab.dart';
import 'package:calcar/screens/workflow/files_tab.dart';
import 'package:calcar/screens/workflow/workflow_models.dart';
import 'package:calcar/screens/workflow/workflow_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// P6 slice 3 gate: default tab, tab switching, approval inertness,
// destructive confirm, retry, truncation notices. Canned constructor
// data only, no network.

const int now = 1700000000000;

WorkflowDetail _detail({
  List<ApprovalRequest>? approvals,
  List<ChatMessage>? messages,
  List<String>? terminalLines,
  int? terminalTotalLines,
  List<FileHunk>? hunks,
  bool filesTruncated = false,
}) {
  return WorkflowDetail(
    workflowId: 'wf-1',
    title: 'Demo workflow',
    status: 'running',
    approvals: approvals ??
        const <ApprovalRequest>[
          ApprovalRequest(
            approvalId: 'ap-1',
            title: 'Run tests',
            detail: 'npm test in agent/',
            expiresAtMillis: now + 90000,
          ),
        ],
    activity: const <ActivityEntry>[
      ActivityEntry(
        id: 'ev-1',
        kind: 'started',
        text: 'Workflow started',
        atMillis: now - 60000,
      ),
    ],
    messages: messages ??
        const <ChatMessage>[
          ChatMessage(messageId: 'm-1', body: 'hello agent'),
        ],
    terminalLines: terminalLines ?? const <String>['line one'],
    terminalTotalLines: terminalTotalLines ?? 1,
    files: hunks ??
        const <FileHunk>[
          FileHunk(path: 'a.txt', diff: '+hi'),
        ],
    filesTruncated: filesTruncated,
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  WorkflowDetail detail, {
  void Function(String body, {required bool destructive})? onSend,
  void Function(String messageId)? onRetry,
  void Function(String approvalId, bool approved)? onResolve,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WorkflowScreen(
        workflow: detail,
        nowMillis: now,
        onSendMessage: onSend,
        onRetryMessage: onRetry,
        onResolveApproval: onResolve,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('workflow screen', () {
    testWidgets('contract: Activity tab is the default tab', (tester) async {
      await _pumpScreen(tester, _detail());
      expect(find.text('Run tests'), findsOneWidget);
      expect(find.text('Workflow started'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-input')), findsNothing);
    });

    testWidgets('contract: tab switching reveals Chat, Terminal, Files',
        (tester) async {
      await _pumpScreen(tester, _detail());
      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();
      expect(find.text('line one'), findsOneWidget);
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      expect(find.text('a.txt'), findsOneWidget);
    });

    testWidgets(
        'contract: expired approval renders inert with no enabled actions and no resend',
        (tester) async {
      const ApprovalRequest expired = ApprovalRequest(
        approvalId: 'ap-exp',
        title: 'Old approval',
        detail: 'too late',
        expiresAtMillis: now - 1000,
      );
      await _pumpScreen(tester, _detail(approvals: const [expired]));
      expect(find.text('Expired'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('approve-ap-exp')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('reject-ap-exp')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Resend'), findsNothing);
    });

    testWidgets('contract: resolved approval renders inert', (tester) async {
      const ApprovalRequest resolved = ApprovalRequest(
        approvalId: 'ap-res',
        title: 'Done approval',
        detail: 'already decided',
        expiresAtMillis: now + 90000,
        resolution: 'approved',
      );
      String? resolvedId;
      await _pumpScreen(
        tester,
        _detail(approvals: const [resolved]),
        onResolve: (String id, bool approved) => resolvedId = id,
      );
      expect(find.text('Resolved: approved'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('approve-ap-res')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('approve-ap-res')));
      await tester.pumpAndSettle();
      expect(resolvedId, isNull);
    });

    testWidgets('contract: pending approval shows countdown and live actions',
        (tester) async {
      String? resolvedId;
      bool? decision;
      await _pumpScreen(
        tester,
        _detail(),
        onResolve: (String id, bool approved) {
          resolvedId = id;
          decision = approved;
        },
      );
      expect(find.textContaining('Expires in'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('approve-ap-1')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('approve-ap-1')));
      await tester.pumpAndSettle();
      expect(resolvedId, 'ap-1');
      expect(decision, isTrue);
    });

    testWidgets('contract: destructive send needs confirm sheet',
        (tester) async {
      final List<Map<String, Object>> sent = <Map<String, Object>>[];
      await _pumpScreen(
        tester,
        _detail(),
        onSend: (String body, {required bool destructive}) {
          sent.add(<String, Object>{'body': body, 'destructive': destructive});
        },
      );
      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        'rm -rf build',
      );
      await tester.tap(find.byKey(const ValueKey('destructive-send')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('destructive-confirm-sheet')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('destructive-cancel')));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      await tester.tap(find.byKey(const ValueKey('destructive-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('destructive-confirm')));
      await tester.pumpAndSettle();
      expect(sent.length, 1);
      expect(sent.single['destructive'], isTrue);
    });

    testWidgets('contract: sending dispatches at once and clears the composer',
        (tester) async {
      final List<String> sent = <String>[];
      await _pumpScreen(
        tester,
        _detail(),
        onSend: (String body, {required bool destructive}) {
          sent.add(body);
        },
      );
      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('chat-input')),
        'keep going',
      );
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await tester.pumpAndSettle();
      expect(sent, <String>['keep going']);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('chat-input')))
            .controller
            ?.text,
        isEmpty,
      );
    });

    testWidgets('contract: failed outbound message offers retry',
        (tester) async {
      const ChatMessage failed = ChatMessage(
        messageId: 'm-9',
        body: 'lost message',
        outbound: true,
        sendState: 'failed',
      );
      String? retried;
      await _pumpScreen(
        tester,
        _detail(messages: const [failed]),
        onRetry: (String id) => retried = id,
      );
      await tester.tap(find.text('Chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('retry-m-9')));
      await tester.pumpAndSettle();
      expect(retried, 'm-9');
    });

    testWidgets(
        'contract: terminal truncation notice appears when the tail is capped',
        (tester) async {
      await _pumpScreen(
        tester,
        _detail(
          terminalLines: const <String>['tail a', 'tail b'],
          terminalTotalLines: 2000,
        ),
      );
      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal-truncated-notice')),
        findsOneWidget,
      );
      expect(find.textContaining('truncated'), findsOneWidget);
    });

    testWidgets('contract: full terminal tail shows no truncation notice',
        (tester) async {
      await _pumpScreen(tester, _detail());
      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal-truncated-notice')),
        findsNothing,
      );
    });

    testWidgets(
        'contract: files truncation notice appears when hunks are capped',
        (tester) async {
      const FileHunk hunk = FileHunk(
        path: 'big.patch',
        diff: '+lots',
        truncated: true,
      );
      await _pumpScreen(
        tester,
        _detail(hunks: const [hunk], filesTruncated: true),
      );
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('files-truncated-notice')),
        findsOneWidget,
      );
      expect(find.text('...truncated'), findsOneWidget);
    });
  });
}
