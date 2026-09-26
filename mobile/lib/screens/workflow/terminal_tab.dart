import 'package:flutter/material.dart';

/// Paged terminal tail. The caller hands over the visible lines plus the
/// true total so the view can announce truncation. Pages move through
/// [onPage]; pages are 1-based.
class TerminalTab extends StatelessWidget {
  final List<String> lines;
  final int totalLines;
  final int page;
  final int totalPages;
  final void Function(int page)? onPage;

  const TerminalTab({
    super.key,
    required this.lines,
    required this.totalLines,
    this.page = 1,
    this.totalPages = 1,
    this.onPage,
  });

  bool get truncated => totalLines > lines.length;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        if (truncated)
          Container(
            key: const ValueKey('terminal-truncated-notice'),
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.amber.shade100,
            child: Text(
              'Showing last ${lines.length} of $totalLines lines (truncated)',
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: lines.length,
            itemBuilder: (BuildContext context, int index) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 1,
                ),
                child: Text(
                  lines[index],
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              );
            },
          ),
        ),
        if (totalPages > 1)
          SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                TextButton(
                  key: const ValueKey('terminal-prev'),
                  onPressed: page > 1 ? () => onPage?.call(page - 1) : null,
                  child: const Text('Prev'),
                ),
                Text('Page $page of $totalPages'),
                TextButton(
                  key: const ValueKey('terminal-next'),
                  onPressed: page < totalPages
                      ? () => onPage?.call(page + 1)
                      : null,
                  child: const Text('Next'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
