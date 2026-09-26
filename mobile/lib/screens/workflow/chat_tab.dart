import 'dart:async';

import 'package:flutter/material.dart';

/// One chat message. Outbound messages carry a send state so the UI can
/// show optimistic pending rows and retry affordances on failure.
class ChatMessage {
  final String messageId;
  final String body;
  final bool outbound;
  final String sendState;
  final bool destructive;

  const ChatMessage({
    required this.messageId,
    required this.body,
    this.outbound = false,
    this.sendState = 'sent',
    this.destructive = false,
  });
}

/// Chat tab: builder list of messages, optimistic composer, retry on
/// failed rows, destructive sends gated behind a confirm sheet. Sends are
/// reported through callbacks; the parent owns the list and the retry
/// policy. No sockets here, so dispose only drops the text controller.
class ChatTab extends StatefulWidget {
  final List<ChatMessage> messages;
  final void Function(String body, {required bool destructive})? onSend;
  final void Function(String messageId)? onRetry;

  const ChatTab({
    super.key,
    required this.messages,
    this.onSend,
    this.onRetry,
  });

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _sendNormal() {
    final String text = _controller.text.trim();
    if (text.isEmpty) {
      return;
    }
    widget.onSend?.call(text, destructive: false);
    _controller.clear();
  }

  void _askDestructive() {
    final String text = _controller.text.trim();
    if (text.isEmpty) {
      return;
    }
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (BuildContext sheetContext) {
          return SafeArea(
            key: const ValueKey('destructive-confirm-sheet'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('This action is destructive. Send anyway?'),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      TextButton(
                        key: const ValueKey('destructive-cancel'),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('destructive-confirm'),
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          widget.onSend?.call(text, destructive: true);
                          _controller.clear();
                        },
                        child: const Text('Confirm'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView.builder(
            itemCount: widget.messages.length,
            itemBuilder: (BuildContext context, int index) {
              return _messageRow(widget.messages[index]);
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey('chat-input'),
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Send an instruction',
                    ),
                    onSubmitted: (_) => _sendNormal(),
                  ),
                ),
                IconButton(
                  key: const ValueKey('chat-send'),
                  icon: const Icon(Icons.send),
                  onPressed: _sendNormal,
                ),
                IconButton(
                  key: const ValueKey('destructive-send'),
                  icon: const Icon(Icons.warning),
                  onPressed: _askDestructive,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _messageRow(ChatMessage message) {
    final bool failed = message.outbound && message.sendState == 'failed';
    final bool pending = message.outbound && message.sendState == 'pending';
    return ListTile(
      key: ValueKey('message-${message.messageId}'),
      title: Text(message.body),
      subtitle: message.outbound
          ? Text(message.sendState)
          : const Text('agent'),
      trailing: failed
          ? TextButton(
              key: ValueKey('retry-${message.messageId}'),
              onPressed: () => widget.onRetry?.call(message.messageId),
              child: const Text('Retry'),
            )
          : pending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
    );
  }
}
