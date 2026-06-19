import 'package:flutter/material.dart';

import '../../../models/chapter_content.dart';

/// Chat chapter view: messaging-style bubbles. Plan §4.5 + §5.4.
/// Speaker-side is server-supplied (`left` / `right` / `narration`).
class ChatChapterView extends StatelessWidget {
  const ChatChapterView({
    super.key,
    required this.participants,
    required this.messages,
    this.scrollController,
  });

  final List<ChatParticipant> participants;
  final List<ChatMessage> messages;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final p in participants) p.id: p};
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      itemCount: messages.length,
      itemBuilder: (_, i) {
        final m = messages[i];
        if (m.side == 'narration') {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: Center(
              child: Text(
                m.text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
              ),
            ),
          );
        }
        final isRight = m.side == 'right';
        final speaker = m.speakerId == null ? null : byId[m.speakerId];
        final bubbleColor =
            _resolveBubbleColor(speaker, isRight, context);
        return Align(
          alignment: isRight ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 280),
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(12),
                topRight: const Radius.circular(12),
                bottomLeft: Radius.circular(isRight ? 12 : 4),
                bottomRight: Radius.circular(isRight ? 4 : 12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (speaker != null && !isRight)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      speaker.name,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _parseColor(speaker.color) ??
                            Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                Text(
                  m.text,
                  style: TextStyle(
                    color: isRight
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color? _resolveBubbleColor(
    ChatParticipant? speaker,
    bool isRight,
    BuildContext context,
  ) {
    if (isRight) {
      return _parseColor(speaker?.color) ??
          Theme.of(context).colorScheme.primary;
    }
    return Theme.of(context).colorScheme.surfaceContainerHighest;
  }

  Color? _parseColor(String? hex) {
    if (hex == null) return null;
    final v = hex.replaceFirst('#', '');
    if (v.length != 6) return null;
    return Color(int.parse('FF$v', radix: 16));
  }
}
