// Hard resource caps for the P6 thin client (PLAN.md P6 envelope).
//
// Every list below is trimmed at insert time, newest data wins, so a
// flooded agent stream can never grow phone memory without bound.
// Screens render with ListView builders over the kept items and announce
// truncation from the totals the controllers track alongside the tails.
import 'dart:convert';

/// Last chat messages kept per workflow. Older rows page from the agent.
const int kChatCap = 300;

/// Activity ring entries kept per workflow. Important pins stay upstream.
const int kActivityCap = 500;

/// Terminal tail lines kept per workflow.
const int kTerminalLineCap = 2000;

/// Terminal tail byte budget (UTF-8) applied with [kTerminalLineCap].
const int kTerminalByteCap = 256 * 1024;

/// Diff files kept per workflow. The first files win.
const int kDiffFileCap = 50;

/// Diff byte budget (UTF-8) applied with [kDiffFileCap].
const int kDiffByteCap = 200 * 1024;

/// Keeps the last [cap] items. Always returns an unmodifiable list.
List<T> tailOf<T>(List<T> items, int cap) {
  if (items.length <= cap) {
    return List<T>.unmodifiable(items);
  }
  return List<T>.unmodifiable(items.sublist(items.length - cap));
}

/// Keeps the terminal tail: at most [kTerminalLineCap] newest lines whose
/// UTF-8 bytes fit [kTerminalByteCap]. Newest lines win; a single line
/// larger than the whole budget clears the tail. Always returns an
/// unmodifiable list.
List<String> capTerminalTail(List<String> lines) {
  int start = lines.length - kTerminalLineCap;
  if (start < 0) {
    start = 0;
  }
  int bytes = 0;
  int cut = start;
  for (int i = lines.length - 1; i >= start; i--) {
    bytes += utf8.encode(lines[i]).length + 1;
    if (bytes > kTerminalByteCap) {
      cut = i + 1;
      break;
    }
  }
  return List<String>.unmodifiable(lines.sublist(cut));
}
