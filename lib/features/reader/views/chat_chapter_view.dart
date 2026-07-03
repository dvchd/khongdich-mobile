import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../models/chapter_content.dart';

/// Chat chapter view — Messenger-style bubbles with progressive reveal.
///
/// Matches the web's `chatFullReader()` mechanism:
///   - Messages are revealed one-by-one on tap (progressive reveal).
///   - "Me" character (named "bạn"/"ban"/"tôi"/"toi"/"ta") → right side.
///   - Other characters → left side with avatar + colored name.
///   - Message types: dialogue (left/right), action (✦ italic),
///     narration (centered), system (small muted).
///   - When all messages are revealed, show end-of-chapter navigation.
class ChatChapterView extends StatefulWidget {
  const ChatChapterView({
    super.key,
    required this.participants,
    required this.messages,
    this.scrollController,
    this.onNext,
    this.onPrev,
  });

  final List<ChatParticipant> participants;
  final List<ChatMessage> messages;
  final ScrollController? scrollController;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;

  @override
  State<ChatChapterView> createState() => _ChatChapterViewState();
}

class _ChatChapterViewState extends State<ChatChapterView> {
  int _revealed = 0;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  ChatParticipant? get _meCharacter {
    return widget.participants.cast<ChatParticipant?>().firstWhere((p) {
      if (p == null) return false;
      final name = p.name.toLowerCase().trim();
      return name == 'bạn' ||
          name == 'ban' ||
          name == 'tôi' ||
          name == 'toi' ||
          name == 'ta';
    }, orElse: () => null);
  }

  bool _isMe(ChatMessage msg) {
    if (msg.characterId == null) return false;
    final meChar = _meCharacter;
    if (meChar != null && msg.characterId == meChar.id) return true;
    final byId = {for (final p in widget.participants) p.id: p};
    final char = byId[msg.characterId];
    if (char != null) {
      final name = char.name.toLowerCase().trim();
      return name == 'bạn' ||
          name == 'ban' ||
          name == 'tôi' ||
          name == 'toi' ||
          name == 'ta';
    }
    return false;
  }

  void _revealNext() {
    if (_revealed < widget.messages.length) {
      setState(() {
        _revealed++;
      });
      // Auto-scroll to the new message
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _revealAll() {
    setState(() {
      _revealed = widget.messages.length;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final byId = {for (final p in widget.participants) p.id: p};
    final visibleMessages = widget.messages.take(_revealed).toList();
    final hasMore = _revealed < widget.messages.length;

    return GestureDetector(
      onTap: _revealNext,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            itemCount: visibleMessages.length + (hasMore ? 0 : 1),
            itemBuilder: (_, i) {
              if (i == visibleMessages.length) {
                // End of chapter
                return _EndOfChapter(
                  onReplay: () {
                    setState(() => _revealed = 0);
                  },
                  onNext: widget.onNext,
                  onPrev: widget.onPrev,
                );
              }
              final msg = visibleMessages[i];
              final character = msg.characterId == null
                  ? null
                  : byId[msg.characterId];

              switch (msg.messageType) {
                case 'action':
                  return _ActionMessage(content: msg.content);
                case 'narration':
                  return _NarrationMessage(content: msg.content);
                case 'system':
                  return _SystemMessage(content: msg.content);
                default:
                  final isMe = _isMe(msg);
                  if (isMe) {
                    return _RightBubble(
                      character: character,
                      content: msg.content,
                      imageUrl: msg.imageUrl,
                    );
                  } else {
                    return _LeftBubble(
                      character: character,
                      content: msg.content,
                      imageUrl: msg.imageUrl,
                    );
                  }
              }
            },
          ),
          // "Tap to continue" hint at the bottom
          if (hasMore)
            Positioned(
              bottom: 12,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _revealAll,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Chạm để xem tiếp ($_revealed/${widget.messages.length})',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Message widgets ─────────────────────────────────────────────

class _LeftBubble extends StatelessWidget {
  const _LeftBubble({
    required this.character,
    required this.content,
    this.imageUrl,
  });
  final ChatParticipant? character;
  final String content;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(character?.color) ?? Colors.grey.shade600;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(character: character, fallbackColor: color),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              constraints: BoxConstraints.loose(const Size.fromWidth(280)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (character != null) ...[
                    Text(
                      character!.name.isEmpty ? 'Không tên' : character!.name,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                  if (imageUrl != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: imageUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                    if (content.isNotEmpty) const SizedBox(height: 4),
                  ],
                  if (content.isNotEmpty)
                    Text(
                      content,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RightBubble extends StatelessWidget {
  const _RightBubble({
    required this.character,
    required this.content,
    this.imageUrl,
  });
  final ChatParticipant? character;
  final String content;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              constraints: BoxConstraints.loose(const Size.fromWidth(280)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFF0084FF),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(4),
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (imageUrl != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: imageUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                    if (content.isNotEmpty) const SizedBox(height: 4),
                  ],
                  if (content.isNotEmpty)
                    Text(content, style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _Avatar(
            character: character,
            fallbackColor: const Color(0xFF0084FF),
            isMe: true,
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.character,
    required this.fallbackColor,
    this.isMe = false,
  });
  final ChatParticipant? character;
  final Color fallbackColor;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    if (character == null) return const SizedBox(width: 36, height: 36);
    if (character!.avatarUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: CachedNetworkImage(
          imageUrl: character!.avatarUrl!,
          width: 36,
          height: 36,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    final name = character?.name ?? '?';
    final displayName = isMe ? 'Bạn' : name;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: fallbackColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Center(
        child: Text(
          displayName.isEmpty ? '?' : displayName[0].toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}

class _ActionMessage extends StatelessWidget {
  const _ActionMessage({required this.content});
  final String content;
  @override
  Widget build(BuildContext context) {
    if (content.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Center(
        child: Text(
          '✦ $content',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontStyle: FontStyle.italic,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

class _NarrationMessage extends StatelessWidget {
  const _NarrationMessage({required this.content});
  final String content;
  @override
  Widget build(BuildContext context) {
    if (content.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Center(
        child: Text(
          content,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.7),
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

class _SystemMessage extends StatelessWidget {
  const _SystemMessage({required this.content});
  final String content;
  @override
  Widget build(BuildContext context) {
    if (content.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Center(
        child: Text(
          content,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.4),
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _EndOfChapter extends StatelessWidget {
  const _EndOfChapter({this.onReplay, this.onNext, this.onPrev});
  final VoidCallback? onReplay;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const Text(
            '— hết chương —',
            style: TextStyle(color: Colors.grey, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (onPrev != null)
                OutlinedButton.icon(
                  onPressed: onPrev,
                  icon: const Icon(Icons.chevron_left),
                  label: const Text('Trước'),
                ),
              OutlinedButton.icon(
                onPressed: onReplay,
                icon: const Icon(Icons.replay),
                label: const Text('Xem lại'),
              ),
              if (onNext != null)
                FilledButton.icon(
                  onPressed: onNext,
                  icon: const Icon(Icons.chevron_right),
                  label: const Text('Sau'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

Color? _parseColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final v = hex.replaceFirst('#', '');
  if (v.length != 6) return null;
  // Use tryParse instead of parse — a malformed hex string (e.g. "GGGHHH"
  // or "red") would throw FormatException and crash the chat view.
  final parsed = int.tryParse('FF$v', radix: 16);
  return parsed != null ? Color(parsed) : null;
}
