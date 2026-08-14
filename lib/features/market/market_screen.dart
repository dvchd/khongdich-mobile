import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/emoji_picker_sheet.dart';
import '../../core/widgets/emoji_text.dart';
import '../../models/market.dart';
import '../../models/story.dart';
import '../../repositories/market_repository.dart';
import '../home/widgets/story_card.dart';

/// Chợ Phiên — Họp Chợ: realtime chat với tác giả, đọc giả, chủ chợ.
///
/// Mirrors the web home section: story grid + chat feed with master/
/// you badges, relative time, story chips, emoji, and SSE realtime.
/// Messages are capped at 100 on screen (same MAX_ROWS as the web).
class MarketScreen extends ConsumerStatefulWidget {
  const MarketScreen({super.key});

  @override
  ConsumerState<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends ConsumerState<MarketScreen> {
  static const int _maxRows = 100;

  MarketSection? _section;
  String? _error;
  bool _loading = true;
  bool _sending = false;
  String? _notice;
  Timer? _noticeTimer;
  Timer? _flashTimer;
  String? _flashId;
  StreamSubscription<MarketStreamEvent>? _sub;
  final List<MarketMessage> _messages = [];
  final Map<String, GlobalKey> _msgKeys = {};
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _noticeTimer?.cancel();
    _flashTimer?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(marketRepositoryProvider);
      final section = await repo.fetchSection();
      if (!mounted) return;
      setState(() {
        _section = section;
        _messages
          ..clear()
          ..addAll(section.messages);
        _loading = false;
      });
      // Mở chat → tự cuộn xuống tin mới nhất (jump không animate để
      // người dùng vào thẳng khung chat mới nhất như web).
      _scrollToBottom(jump: true, retries: 2);
      _subscribe();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _subscribe() {
    _sub?.cancel();
    final repo = ref.read(marketRepositoryProvider);
    _sub = repo.subscribeToStream((event) {
      if (!mounted) return;
      switch (event) {
        case MarketMessageEvent(:final message, :final storyAdded):
          setState(() {
            if (_messages.any((m) => m.id == message.id)) return;
            _messages.add(message);
            if (_messages.length > _maxRows) {
              _messages.removeRange(0, _messages.length - _maxRows);
            }
          });
          if (storyAdded && !_loading) {
            // Refresh the story grid when a message attached a new story.
            unawaited(_refreshStories());
          }
          _scrollToBottom();
        case MarketResetEvent():
          // Weekly wipe / Chủ Chợ change: drop the stale session and pull
          // the fresh section (master, grid, history) in one request.
          setState(() => _messages.clear());
          unawaited(_refreshSection());
        case MarketEditEvent(:final message):
          setState(() {
            final i = _messages.indexWhere((m) => m.id == message.id);
            if (i >= 0) _messages[i] = message;
          });
        case MarketDeleteEvent(:final id):
          setState(() => _messages.removeWhere((m) => m.id == id));
      }
    });
  }

  /// Full section refresh after a session reset: new Chủ Chợ, empty story
  /// grid and fresh history. Best-effort — the stream keeps flowing either
  /// way.
  Future<void> _refreshSection() async {
    try {
      final repo = ref.read(marketRepositoryProvider);
      final section = await repo.fetchSection();
      if (!mounted || _section == null) return;
      setState(() {
        _section = section;
        _messages
          ..clear()
          ..addAll(section.messages);
      });
      _scrollToBottom(jump: true);
    } catch (_) {
      /* best-effort */
    }
  }

  /// Scroll to the replied-to message and flash-highlight its tile. The
  /// parent may have been trimmed from the on-screen list — notice when
  /// it is not available.
  void _jumpToParent(String? parentId) {
    if (parentId == null) return;
    final ctx = _msgKeys[parentId]?.currentContext;
    if (ctx == null) {
      _showNotice('Tin nhắn gốc nằm ngoài phạm vi hiển thị');
      return;
    }
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.4,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
    setState(() => _flashId = parentId);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _flashId = null);
    });
  }

  Future<void> _refreshStories() async {
    try {
      final repo = ref.read(marketRepositoryProvider);
      final section = await repo.fetchSection();
      if (!mounted || _section == null) return;
      setState(() {
        _section = MarketSection(
          open: _section!.open,
          masterUsername: _section!.masterUsername,
          masterDisplayName: _section!.masterDisplayName,
          masterAvatar: _section!.masterAvatar,
          stories: section.stories,
          messages: _section!.messages,
        );
      });
    } catch (_) {
      /* best-effort */
    }
  }

  void _scrollToBottom({bool jump = false, int retries = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        if (jump) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        } else {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      } else if (retries > 0) {
        // ListView chưa attach controller (frame đầu) — thử lại frame sau.
        _scrollToBottom(jump: jump, retries: retries - 1);
      }
    });
  }

  void _showNotice(String text) {
    setState(() => _notice = text);
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    final api = ref.read(apiClientProvider).valueOrNull;
    if (api == null || !await api.isAuthenticated()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đăng nhập để tham gia Họp Chợ.')),
        );
        context.push('/auth');
      }
      return;
    }
    setState(() => _sending = true);
    try {
      final result = await ref
          .read(marketRepositoryProvider)
          .postMessage(text);
      if (!mounted) return;
      if (result.hidden) {
        _showNotice('Tin nhắn bị ẩn do vi phạm quy định');
        _composer.clear();
      } else {
        setState(() {
          if (_messages.any((m) => m.id == result.message.id)) return;
          _messages.add(result.message);
          if (_messages.length > _maxRows) {
            _messages.removeRange(0, _messages.length - _maxRows);
          }
        });
        _composer.clear();
        _scrollToBottom();
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e is ApiException ? e.message : 'Mất kết nối, thử lại sau';
      _showNotice(msg);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _insertEmoji() async {
    final shortcode = await showEmojiPickerSheet(context);
    if (shortcode == null) return;
    final value = _composer.text;
    final selection = _composer.selection;
    final start = selection.isValid ? selection.start : value.length;
    final end = selection.isValid ? selection.end : value.length;
    final next = value.replaceRange(start, end, shortcode);
    _composer.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + shortcode.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final section = _section;
    final closed = section != null && !section.open;
    return Scaffold(
      appBar: AppBar(
        title: const Text('🛒 Chợ Phiên'),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (section != null && section.masterName != null)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    closed ? Icons.storefront_outlined : Icons.storefront,
                    size: 18,
                    color: closed
                        ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      closed
                          ? 'Chợ Phiên đang đóng cửa — chủ chợ tuần này: '
                                '${section.masterName}'
                          : 'Chủ chợ tuần này: ${section.masterName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? _ErrorBody(message: _error!, onRetry: _load)
                : _buildContent(section),
          ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _notice!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          _ComposerBar(
            controller: _composer,
            sending: _sending,
            onSend: _send,
            onEmoji: _insertEmoji,
            closed: closed,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(MarketSection? section) {
    final stories = section?.stories ?? const [];
    return ListView(
      controller: _scroll,
      children: [
        if (stories.isNotEmpty) ...[
          const SizedBox(height: 12),
          _StoryRail(stories: stories),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Text('💬 Họp Chợ', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text(
                'chat realtime với tác giả',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withValues(
                            alpha: 0.5,
                          ),
                    ),
              ),
            ],
          ),
        ),
        if (_messages.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                'Chưa có tin nhắn nào. Hãy mở màn!',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        for (final m in _messages)
          _MessageTile(
            key: _msgKeys.putIfAbsent(m.id, GlobalKey.new),
            message: m,
            flash: _flashId == m.id,
            onJumpParent: _jumpToParent,
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _StoryRail extends StatelessWidget {
  const _StoryRail({required this.stories});

  final List<StorySummary> stories;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 246,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: stories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final s = stories[i];
          return SizedBox(
            width: 120,
            child: StoryCard(
              story: s,
              onTap: () => context.push('/story/${s.slug}'),
            ),
          );
        },
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({
    super.key,
    required this.message,
    required this.flash,
    required this.onJumpParent,
  });

  final MarketMessage message;
  final bool flash;
  final void Function(String? parentId) onJumpParent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = message.displayName.isEmpty
        ? message.username
        : message.displayName;
    final initial = name.isEmpty ? '?' : name.characters.first;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      color: flash ? AppTheme.primary.withValues(alpha: 0.14) : Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
              child: message.avatarUrl == null || message.avatarUrl!.isEmpty
                  ? Text(initial, style: const TextStyle(fontSize: 13))
                  : ClipOval(
                      child: Image.network(
                        message.avatarUrl!,
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Text(
                          initial,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        message.relTime(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurface.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                      if (message.edited)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            '· đã sửa',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurface.withValues(
                                alpha: 0.4,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (message.isReply)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _ReplyChip(
                        message: message,
                        onTap: () => onJumpParent(message.parentId),
                      ),
                    ),
                  if (message.storyTitle != null && message.storySlug != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 2),
                      child: InkWell(
                        onTap: () => context.push('/story/${message.storySlug}'),
                        child: Text(
                          '📖 ${message.storyTitle!} →',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  EmojiText(
                    text: message.content,
                    contentHtml: message.contentHtml,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pill chip "↩ @tên: nội dung…" — identifies the replied-to message in
/// the flat chat flow. Tapping jumps to the parent tile and flashes it.
class _ReplyChip extends StatelessWidget {
  const _ReplyChip({required this.message, required this.onTap});

  final MarketMessage message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = message.parentPreview ?? '';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        constraints: const BoxConstraints(minHeight: 28),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.subdirectory_arrow_left,
              size: 13,
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                message.parentAuthor ?? 'tin đã xóa',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (preview.isNotEmpty) ...[
              const SizedBox(width: 7),
              Container(
                width: 1,
                height: 10,
                color: scheme.outlineVariant,
              ),
              const SizedBox(width: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onEmoji,
    required this.closed,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onEmoji;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(Icons.emoji_emotions_outlined),
              visualDensity: VisualDensity.compact,
              tooltip: 'Chèn emoji',
              onPressed: closed ? null : onEmoji,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !closed,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: closed ? 'Chợ đang đóng cửa' : 'Điều gì đó hay ho…',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send),
              onPressed: sending || closed ? null : onSend,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            const Text('Không tải được Chợ Phiên'),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Thử lại')),
          ],
        ),
      ),
    );
  }
}
