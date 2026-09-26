import 'package:calcar/screens/computer_detail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// P6 slice 3 gate: chip labels per status, lazy sysinfo fetch, workflow
// tap routing, online state. Canned constructor data only, no network.

ComputerSummary _computer({
  bool online = true,
  List<WorkflowSummary>? workflows,
}) {
  return ComputerSummary(
    deviceId: 'pc-1',
    displayName: 'Work PC',
    online: online,
    lastSeenMillis: 1700000000000,
    workflows: workflows ??
        const <WorkflowSummary>[
          WorkflowSummary(
            workflowId: 'wf-1',
            title: 'Build app',
            status: 'running',
          ),
        ],
  );
}

void main() {
  group('computer detail', () {
    testWidgets(
        'contract: every workflow status renders its chip label', (tester) async {
      const List<WorkflowSummary> workflows = <WorkflowSummary>[
        WorkflowSummary(workflowId: 'a', title: 'A', status: 'running'),
        WorkflowSummary(workflowId: 'b', title: 'B', status: 'waiting_input'),
        WorkflowSummary(
          workflowId: 'c',
          title: 'C',
          status: 'waiting_approval',
        ),
        WorkflowSummary(workflowId: 'd', title: 'D', status: 'completed'),
        WorkflowSummary(workflowId: 'e', title: 'E', status: 'failed'),
        WorkflowSummary(workflowId: 'f', title: 'F', status: 'stopped'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: ComputerDetailScreen(computer: _computer(workflows: workflows)),
        ),
      );
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Waiting input'), findsOneWidget);
      expect(find.text('Waiting approval'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Stopped'), findsOneWidget);
    });

    testWidgets('contract: sysinfo stays collapsed until expanded',
        (tester) async {
      int calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ComputerDetailScreen(
            computer: _computer(),
            onExpandSysinfo: () {
              calls += 1;
              return Future<Sysinfo>.value(
                const Sysinfo(
                  cpu: 'cpu-x',
                  ram: 'ram-x',
                  gpu: 'gpu-x',
                  disk: 'disk-x',
                ),
              );
            },
          ),
        ),
      );
      expect(calls, 0);
      expect(find.text('cpu-x'), findsNothing);
      expect(find.text('System info'), findsOneWidget);
    });

    testWidgets('contract: expanding sysinfo fetches lazily through onExpand',
        (tester) async {
      int calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ComputerDetailScreen(
            computer: _computer(),
            onExpandSysinfo: () {
              calls += 1;
              return Future<Sysinfo>.value(
                const Sysinfo(
                  cpu: 'Ryzen 7',
                  ram: '16 GB',
                  gpu: 'RTX 4060',
                  disk: '512 GB free',
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('System info'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('CPU'), findsOneWidget);
      expect(find.text('Ryzen 7'), findsOneWidget);
      expect(find.text('RAM'), findsOneWidget);
      expect(find.text('GPU'), findsOneWidget);
      expect(find.text('Disk'), findsOneWidget);
    });

    testWidgets(
        'contract: tapping a workflow reports it through onOpenWorkflow',
        (tester) async {
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: ComputerDetailScreen(
            computer: _computer(),
            onOpenWorkflow: (WorkflowSummary workflow) {
              opened = workflow.workflowId;
            },
          ),
        ),
      );
      await tester.tap(find.text('Build app'));
      await tester.pumpAndSettle();
      expect(opened, 'wf-1');
    });

    testWidgets('contract: offline computer shows offline state',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ComputerDetailScreen(computer: _computer(online: false)),
        ),
      );
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Online'), findsNothing);
    });
  });
}
