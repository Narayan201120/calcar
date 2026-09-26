import 'package:flutter/material.dart';

/// One capped file diff hunk. [truncated] marks a hunk cut by the cap.
class FileHunk {
  final String path;
  final String diff;
  final bool truncated;

  const FileHunk({
    required this.path,
    required this.diff,
    this.truncated = false,
  });
}

/// Capped file diffs. Announces truncation both overall and per hunk so
/// a cut diff never reads as a complete one.
class FilesTab extends StatelessWidget {
  final List<FileHunk> hunks;
  final bool truncated;

  const FilesTab({
    super.key,
    required this.hunks,
    this.truncated = false,
  });

  bool get _announce =>
      truncated || hunks.any((FileHunk hunk) => hunk.truncated);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        if (_announce)
          Container(
            key: const ValueKey('files-truncated-notice'),
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.amber.shade100,
            child: Text(
              'Diff capped at ${hunks.length} files, output truncated',
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: hunks.length,
            itemBuilder: (BuildContext context, int index) {
              final FileHunk hunk = hunks[index];
              return Card(
                key: ValueKey('hunk-${hunk.path}'),
                child: ListTile(
                  title: Text(hunk.path),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        hunk.diff,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      if (hunk.truncated) const Text('...truncated'),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
