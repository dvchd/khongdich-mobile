import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../models/chapter_content.dart';

/// Chat chapter view — Messenger-style bubbles. Matches the web's
/// `chatFullReader()` mechanism:
///
///   - **"Me" character detection**: auto-detects from participant
///     named "bạn"/"ban"/"tôi"/"toi"/"ta" → right side (blue bubble).
///   - **Other characters**: left side (grey bubble) with avatar +
///     colored name.
///   - **Message types**:
///     - `dialogue`: left/right bubble with avatar + name + text/image
///     - `action`: centered italic with ✦ prefix
///     - `narration`: centered regular text
///     - `system`: centered small muted text
///   - **Avatar**: if `avatar_url` is set, show image; otherwise show
///     first letter of the name on a colored circle.
///   - **Image messages**: `image_url` rendered inside the bubble.
///
/// Unlike the web's typewriter reveal, the mobile version shows all
/// messages at once (no progressive reveal). This is simpler and more
/// appropriate for a scrollable mobile list.
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

  /// Detect the "me" character — matches web's `isMe()` logic:
  /// character named "bạn", "ban", "tôi", "toi", or "ta".
  ChatParticipant? get _meCharacter {
    return participants.cast<ChatParticipant?>().firstWhere(
          (p) {
            if (p == null) return false;
            final name = p.name.toLowerCase().trim();
            return name == 'bạn' ||
                name == 'ban' ||
                name == 'tôi' ||
                name == 'toi' ||
                name == 'ta';
          },
          orElse: () => null,
        );
  }

  /// Check if a message is from the "me" character.
  bool _isMe(ChatMessage msg, ChatParticipant? meChar) {
    if (msg.characterId == null) return false;
    if (meChar != null && msg.characterId == meChar.id) return true;
    // Fallback: check by name (same as web)
    final byId = {for (final p in participants) p.id: p};
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

  @override
  Widget build(BuildContext context) {
    final byId = {for (final p in participants) p.id: p};
    final meChar = _meCharacter;

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      itemCount: messages.length,
      itemBuilder: (_, i) {
        final msg = messages[i];
        final character =
            msg.characterId == null ? null : byId[msg.characterId];

        switch (msg.messageType) {
          case 'action':
            return _ActionMessage(content: msg.content);
          case 'narration':
            return _NarrationMessage(content: msg.content);
          case 'system':
            return _SystemMessage(content: msg.content);
          default:
            // dialogue
            final isMe = _isMe(msg, meChar);
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
    );
  }
}

// ─── Message widgets ─────────────────────────────────────────────

/// Left-aligned bubble for other characters. Shows avatar (image or
/// first-letter fallback), colored name, then text/image content.
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
          // Avatar
          _Avatar(character: character, fallbackColor: color),
          const SizedBox(width: 8),
          // Bubble
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
                  // Character name (colored)
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
                  // Image (if any)
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
                  // Text content
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

/// Right-aligned bubble for "me" character. Blue bubble, no name label
/// (matches Messenger style).
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
          // Bubble
          Flexible(
            child: Container(
              constraints: BoxConstraints.loose(const Size.fromWidth(280)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0084FF),
                borderRadius: const BorderRadius.only(
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
                  // Image (if any)
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
                  // Text content
                  if (content.isNotEmpty)
                    Text(
                      content,
                      style: const TextStyle(color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Avatar
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

/// Avatar widget: shows image if available, otherwise first-letter
/// fallback with the character's color.
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

/// Action message: centered italic with ✦ prefix.
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
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

/// Narration message: centered regular text.
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
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

/// System message: centered small muted text.
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
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────────────

Color? _parseColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final v = hex.replaceFirst('#', '');
  if (v.length != 6) return null;
  return Color(int.parse('FF$v', radix: 16));
}
