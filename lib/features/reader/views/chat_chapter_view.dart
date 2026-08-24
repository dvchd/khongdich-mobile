import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/network/app_image_cache.dart';
import '../../../models/chapter_content.dart';

/// Chat chapter view — mô phỏng cơ chế `chatFullReader()` của web:
///
///   - Reveal tuần tự với hiệu ứng giả lập app chat:
///       · Tin của nhân vật khác → chỉ báo "X đang gõ..." (25ms/ký tự,
///         kẹp 400–1500ms) rồi bubble mới hiện.
///       · Tin của "Bạn" → giả thanh input gõ dần từng ký tự (35ms/ký tự)
///         rồi mới "gửi" sang bubble phải.
///       · action/narration/system → hiện ngay.
///   - Chạm khi đang animate = bỏ qua hiệu ứng, hiện ngay kết quả.
///   - "Me" character: tên "bạn"/"ban"/"tôi"/"toi"/"ta" → bên phải.
///   - Hết chương: nav hiện sau 1.2s như web.
class ChatChapterView extends StatefulWidget {
  const ChatChapterView({
    super.key,
    required this.participants,
    required this.messages,
    this.scrollController,
    this.onNext,
    this.onPrev,
    this.onAllRevealed,
  });

  final List<ChatParticipant> participants;
  final List<ChatMessage> messages;
  final ScrollController? scrollController;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;

  /// Fired once when all messages have been revealed — the reader body
  /// uses it to mark reading progress (the chat list doesn't attach to
  /// the shared scroll controller).
  final VoidCallback? onAllRevealed;

  @override
  State<ChatChapterView> createState() => _ChatChapterViewState();
}

class _ChatChapterViewState extends State<ChatChapterView> {
  /// Số tin đã hiển thị (giống `revealed` bên web).
  int _revealed = 0;

  /// Tên nhân vật đang hiện chỉ báo "đang gõ..." (null = không có).
  String? _typingCharName;

  /// Đang mô phỏng thanh input gõ dần cho tin của "Bạn".
  bool _inputTyping = false;
  String _inputText = '';

  /// Gõ XONG, chờ người đọc bấm Gửi (mirror web: sendInput mới quyết
  /// định đưa tin lên — không tự động gửi).
  bool _inputReady = false;

  /// Nav cuối chương đã hiện chưa (web: trễ 1200ms).
  bool _showEndNav = false;
  bool _allRevealedFired = false;

  Timer? _timer;
  final _fallbackScrollController = ScrollController();

  /// Đã chạy lần `_startNext` đầu tiên cho chương hiện tại chưa — chống
  /// double-start khi cả `initState` lẫn `didUpdateWidget` cùng lịch
  /// post-frame callback (đổi chương trước frame đầu tiên → 2 callback
  /// cùng chạy trên chương mới, reveal/skip tin đầu 2 lần).
  bool _started = false;

  ScrollController get _controller =>
      widget.scrollController ?? _fallbackScrollController;

  bool get _hasMore => _revealed < widget.messages.length;

  /// Hint cuối luồng cuốn (mirror các phần tử cuối #chat-fs-messages):
  /// 'typing' = chỉ báo đang gõ; 'send' = chờ bấm Gửi; 'tap' = chạm để tiếp.
  String? get _trailingKind {
    if (_typingCharName != null) return 'typing';
    if (_inputTyping && _inputReady) return 'send';
    // Đang gõ giả thanh input cho tin "Bạn": thanh input chính là focus —
    // không hiện hint 'tap' (tap đang bị bỏ qua, hiện sẽ gây mâu thuẫn).
    if (_inputTyping) return null;
    if (_hasMore && !_showEndNav) return 'tap';
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startInitial());
  }

  @override
  void didUpdateWidget(covariant ChatChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset toàn bộ khi đổi chương — hủy timer trước để không leak callback
    // trỏ vào danh sách message cũ.
    if (oldWidget.messages != widget.messages) {
      _timer?.cancel();
      _timer = null;
      _revealed = 0;
      _started = false;
      _typingCharName = null;
      _inputTyping = false;
      _inputReady = false;
      _inputText = '';
      _showEndNav = false;
      _allRevealedFired = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _startInitial());
    }
  }

  /// Lần chạy đầu tiên của mỗi chương — idempotent (xem [_started]).
  void _startInitial() {
    if (!mounted || _started) return;
    _started = true;
    _startNext();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fallbackScrollController.dispose();
    super.dispose();
  }

  ChatParticipant? get _meCharacter {
    return widget.participants.cast<ChatParticipant?>().firstWhere((p) {
      if (p == null) return false;
      final name = p.name.toLowerCase().trim();
      return _isMeName(name);
    }, orElse: () => null);
  }

  static bool _isMeName(String lowerName) {
    return lowerName == 'bạn' ||
        lowerName == 'ban' ||
        lowerName == 'tôi' ||
        lowerName == 'toi' ||
        lowerName == 'ta';
  }

  bool _isMe(ChatMessage msg) {
    if (msg.characterId == null) return false;
    final meChar = _meCharacter;
    if (meChar != null && msg.characterId == meChar.id) return true;
    final byId = {for (final p in widget.participants) p.id: p};
    final char = byId[msg.characterId];
    if (char != null) return _isMeName(char.name.toLowerCase().trim());
    return false;
  }

  // ─── Core reveal logic (mirror chatFullReader.revealMessage) ──────

  void _startNext() {
    if (!mounted || !_hasMore) return;
    final msg = widget.messages[_revealed];

    // "Me" dialogue → giả thanh input gõ dần (web: startInputTypewriter).
    if (msg.messageType == 'dialogue' && _isMe(msg)) {
      _startInputTypewriter(msg);
      return;
    }

    // Non-dialogue types hiện ngay — không chỉ báo gõ.
    if (msg.messageType != 'dialogue') {
      _revealCurrent();
      return;
    }

    // Nhân vật khác → "đang gõ..." với delay theo độ dài tin.
    final text = msg.content;
    _typingCharName =
        widget.participants
            .cast<ChatParticipant?>()
            .firstWhere(
              (p) => p != null && p.id == msg.characterId,
              orElse: () => null,
            )
            ?.name ??
        '';
    final delayMs = text.isEmpty
        ? 300
        : (text.length * 25).clamp(400, 1500);
    setState(() {});
    _timer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      // Nhả slot timer TRƯỚC khi reveal — nếu không, _timer giữ object
      // đã fire khiến điều kiện "idle" ở _handleTap sai mãi → tap để
      // sang tin kế bị vô hiệu.
      _timer = null;
      _typingCharName = null;
      _revealCurrent();
    });
  }

  void _revealCurrent() {
    if (!mounted) return;
    setState(() => _revealed++);
    _scrollToBottom();
    _afterMessageRevealed();
  }

  /// Mirror web `afterMessageRevealed`: KHÔNG tự nối chuỗi vô hạn —
  /// sau mỗi tin chỉ "mở sẵn input" nếu tin kế là của "Bạn"; còn lại
  /// dừng, đợi người đọc chạm (web: prefillNextMe).
  void _afterMessageRevealed() {
    if (!_hasMore) {
      _fireAllRevealed();
      // Web: nav cuối chương hiện sau 1200ms.
      _timer = Timer(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        _timer = null;
        setState(() => _showEndNav = true);
      });
      return;
    }
    _prefillNextMe();
  }

  /// Mirror web `prefillNextMe`: tin kế là dialogue của "Bạn" → mở giả
  /// thanh input gõ dần luôn.
  void _prefillNextMe() {
    final next = widget.messages[_revealed];
    if (next.messageType == 'dialogue' && _isMe(next)) {
      _startInputTypewriter(next);
    }
  }

  // ─── Fake input bar typewriter cho tin của "Bạn" ──────────────────

  void _startInputTypewriter(ChatMessage msg) {
    _inputTyping = true;
    _inputReady = false;
    _inputText = '';
    setState(() {});
    _scrollToBottom();

    final text = msg.content;
    if (text.isEmpty) {
      // Tin rỗng — không có gì để "gõ", tự thông qua như web.
      _commitInput();
      return;
    }
    var idx = 0;
    void tick() {
      if (!mounted || !_inputTyping) return;
      idx++;
      setState(() => _inputText = text.substring(0, idx));
      _scrollToBottom();
      if (idx >= text.length) {
        // Mirror web `afterInputTypewriterDone`: gõ XONG thì DỪNG —
        // chờ người đọc bấm Gửi (_onSendPressed) mới đưa tin lên.
        setState(() => _inputReady = true);
      } else {
        _timer = Timer(const Duration(milliseconds: 35), tick);
      }
    }

    _timer = Timer(const Duration(milliseconds: 350), tick);
  }

  /// Mirror web `sendInput`: chỉ nhận khi ĐÃ gõ xong; đưa tin lên rồi
  /// tự chơi đúng MỘT tin kế (150ms non-dialogue / 400ms dialogue).
  void _onSendPressed() {
    if (!_inputReady) return;
    _commitInput();
  }

  void _commitInput() {
    _timer?.cancel();
    _timer = null;
    _inputTyping = false;
    _inputReady = false;
    _inputText = '';
    // Chốt tin kế TRƯỚC khi reveal: _revealCurrent → _prefillNextMe có
    // thể đệ quy qua _commitInput (tin "Bạn" rỗng liên tiếp) làm
    // _revealed tiến tiếp — đọc messages[_revealed] sau reveal sẽ lấy
    // nhầm tin xa hơn và lịch chain TRÙNG với chain bên trong (N chain
    // fire cùng lúc → double-start, skip tin). Lúc này _revealed còn
    // trỏ vào CHÍNH tin đang commit → tin kế là _revealed + 1.
    final nextIndex = _revealed + 1;
    final next = nextIndex < widget.messages.length
        ? widget.messages[nextIndex]
        : null;
    _revealCurrent();
    if (next == null) return;
    // Tin kế là của "Bạn": _prefillNextMe đã mở sẵn typewriter cho nó
    // (timer 350ms đang chạy trong _timer). Schedule chain ở đây sẽ GHI
    // ĐÈ _timer đó → 2 vòng tick song song, text bị xoá gõ lại/nhấp
    // nháy giữa 2 prefix — chỉ schedule chain khi tin kế do chain/tap
    // tự chơi (không thuộc prefill).
    if (next.messageType == 'dialogue' && _isMe(next)) return;
    final delayMs = next.messageType != 'dialogue' ? 150 : 400;
    _timer = Timer(Duration(milliseconds: delayMs), () {
      // Nhả slot trước khi chạy — giữ tham chiếu timer đã fire sẽ khiến
      // _handleTap tưởng "đang bận" → tap để sang tin kế bị vô hiệu.
      _timer = null;
      _startNext();
    });
  }

  // ─── Tap handling ─────────────────────────────────────────────────

  /// Mirror web `revealNext`: đang chỉ báo gõ hoặc đang ở pha input thì
  /// BỎ QUA tap — tiến duy nhất bằng nút Gửi. Idle → chơi tin kế.
  void _handleTap() {
    if (_typingCharName != null || _inputTyping) return;
    if (_hasMore && _timer == null && !_inputReady) _startNext();
  }

  void _fireAllRevealed() {
    if (_allRevealedFired) return;
    _allRevealedFired = true;
    widget.onAllRevealed?.call();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.hasClients) {
        _controller.animateTo(
          _controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ─── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final byId = {for (final p in widget.participants) p.id: p};
    final visibleMessages = widget.messages.take(_revealed).toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.translucent,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _controller,
              padding: const EdgeInsets.symmetric(
                  vertical: 12, horizontal: 8),
              // Mirror web: các hint (đang gõ / chạm / gửi) là PHẦ TỬ TRONG
              // luồng cuốn sau tin cuối — không phải overlay đè lên chữ;
              // "— hết chương —" hiện NGAY khi hết tin, nav trễ 1200ms.
              itemCount: visibleMessages.length +
                  (_trailingKind != null ? 1 : 0) +
                  (!_hasMore && widget.messages.isNotEmpty ? 1 : 0),
              itemBuilder: (_, i) {
                if (i < visibleMessages.length) {
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
                      return isMe
                          ? _RightBubble(
                              character: character,
                              content: msg.content,
                              imageUrl: msg.imageUrl,
                              isDark: isDark,
                            )
                          : _LeftBubble(
                              character: character,
                              content: msg.content,
                              imageUrl: msg.imageUrl,
                              isDark: isDark,
                            );
                  }
                }
                final j = i - visibleMessages.length;
                if (_trailingKind != null) {
                  if (j == 0) {
                    switch (_trailingKind) {
                      case 'typing':
                        return _TypingHint(name: _typingCharName!);
                      case 'send':
                        return const _SendHint();
                      case 'tap':
                        return const _TapHint();
                    }
                  }
                  return _EndOfChapter(
                    showNav: _showEndNav,
                    onReplay: () {
                      setState(() {
                        _revealed = 0;
                        _showEndNav = false;
                        _allRevealedFired = false;
                      });
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _startNext());
                    },
                    onNext: widget.onNext,
                    onPrev: widget.onPrev,
                  );
                }
                if (j == 0) {
                  return _EndOfChapter(
                    showNav: _showEndNav,
                    onReplay: () {
                      setState(() {
                        _revealed = 0;
                        _showEndNav = false;
                        _allRevealedFired = false;
                      });
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _startNext());
                    },
                    onNext: widget.onNext,
                    onPrev: widget.onPrev,
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
          // Giả thanh input khi "Bạn" đang gõ — mirror .chat-fs-input-bar.
          // SafeArea đáy: nhô lên trên thanh điều hướng/gesture pill của
          // hệ thống như các menu khác (trước đây dính sát mép màn).
          if (_inputTyping)
            SafeArea(
              top: false,
              child: _FakeInputBar(
                text: _inputText,
                isDark: isDark,
                ready: _inputReady,
                onSend: _onSendPressed,
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
    required this.isDark,
    this.imageUrl,
  });
  final ChatParticipant? character;
  final String content;
  final String? imageUrl;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(character?.color) ?? Colors.grey.shade600;
    // Mirror .chat-fs-text: #E8E8E8 sáng / #2C2C2E tối, đuôi bubble ở
    // dưới-trái (radius 18 18 18 4).
    final bubbleColor = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE8E8E8);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _Avatar(character: character, fallbackColor: color),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              constraints:
                  BoxConstraints.loose(const Size.fromWidth(280)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(18),
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
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                  if (imageUrl != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                            maxWidth: 220, maxHeight: 220),
                        child: CachedNetworkImage(
                          imageUrl: imageUrl!,
                          cacheManager: AppImageCache.instance,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    if (content.isNotEmpty) const SizedBox(height: 4),
                  ],
                  if (content.isNotEmpty)
                    Text(
                      content,
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.4,
                        color: isDark ? const Color(0xFFE8E8E8) : null,
                      ),
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
    required this.isDark,
    this.imageUrl,
  });
  final ChatParticipant? character;
  final String content;
  final String? imageUrl;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    // Mirror .chat-fs-text-me: #0084FF sáng / #0A7AFF tối, đuôi dưới-phải.
    final bubbleColor =
        isDark ? const Color(0xFF0A7AFF) : const Color(0xFF0084FF);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Container(
              constraints:
                  BoxConstraints.loose(const Size.fromWidth(280)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (imageUrl != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                            maxWidth: 220, maxHeight: 220),
                        child: CachedNetworkImage(
                          imageUrl: imageUrl!,
                          cacheManager: AppImageCache.instance,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    if (content.isNotEmpty) const SizedBox(height: 4),
                  ],
                  if (content.isNotEmpty)
                    Text(
                      content,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 16, height: 1.4),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _Avatar(
            character: character,
            fallbackColor: bubbleColor,
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
    // Mirror .chat-fs-avatar: 32px tròn.
    if (character == null) return const SizedBox(width: 32, height: 32);
    if (character!.avatarUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: CachedNetworkImage(
          imageUrl: character!.avatarUrl!,
          cacheManager: AppImageCache.instance,
          width: 32,
          height: 32,
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
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: fallbackColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Text(
          displayName.isEmpty ? '?' : displayName[0].toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 12,
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
    // Mirror .chat-fs-action: giữa, nghiêng, xám, cỡ .85em.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
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

class _NarrationMessage extends StatelessWidget {
  const _NarrationMessage({required this.content});
  final String content;
  @override
  Widget build(BuildContext context) {
    if (content.isEmpty) return const SizedBox.shrink();
    // Mirror .chat-fs-narration: giữa, IN NGHIÊNG, opacity .75.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Center(
        child: Text(
          content,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontStyle: FontStyle.italic,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.75),
            fontSize: 15,
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
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

/// Chỉ báo "X đang gõ..." với 3 chấm — mirror .chat-fs-typing-hint
/// (centered, xám .8rem, KHÔNG nền).
class _TypingHint extends StatefulWidget {
  const _TypingHint({required this.name});
  final String name;

  @override
  State<_TypingHint> createState() => _TypingHintState();
}

class _TypingHintState extends State<_TypingHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label =
        widget.name.isEmpty ? 'đang gõ...' : '${widget.name} đang gõ...';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (_, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++)
                    Opacity(
                      opacity:
                          (((_c.value * 3) - i).clamp(0.0, 1.0)),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 1.5),
                        child: Icon(Icons.circle, size: 6),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(
            fontSize: 13,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.55),
          )),
        ],
      ),
    );
  }
}

/// "Chạm để tiếp ↓" — mirror .chat-fs-tap-hint (pulse 2s nhẹ nhàng).
class _TapHint extends StatefulWidget {
  const _TapHint();

  @override
  State<_TapHint> createState() => _TapHintState();
}

class _TapHintState extends State<_TapHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.35, end: 0.9).animate(
            CurvedAnimation(parent: _c, curve: Curves.easeInOut),
          ),
          child: Text(
            'Chạm để tiếp ↓',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.9),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Gửi để tiếp ↑" khi input của "Bạn" gõ xong — accent màu Messenger.
class _SendHint extends StatelessWidget {
  const _SendHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Text(
          'Gửi để tiếp ↑',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF0A7AFF)
                : const Color(0xFF0084FF),
          ),
        ),
      ),
    );
  }
}

/// Giả thanh input khi "Bạn" đang gõ — mirror .chat-fs-input-bar.
class _FakeInputBar extends StatelessWidget {
  const _FakeInputBar({
    required this.text,
    required this.isDark,
    required this.ready,
    required this.onSend,
  });
  final String text;
  final bool isDark;

  /// Gõ xong, chờ bấm Gửi — mirror web sendInput.
  final bool ready;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final wrapColor = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF0F0F0);
    final sendColor = ready
        ? (isDark ? const Color(0xFF0A7AFF) : const Color(0xFF0084FF))
        : Colors.grey;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE6E6E0),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: wrapColor,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Text.rich(
                TextSpan(
                  text: text,
                  children: const [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: _BlinkingCaret(),
                    ),
                  ],
                ),
                style: TextStyle(
                  fontSize: 16,
                  height: 1.4,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                maxLines: 4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: ready ? onSend : null,
            icon: Icon(Icons.send, size: 22, color: sendColor),
            tooltip: 'Gửi',
          ),
        ],
      ),
    );
  }
}

class _BlinkingCaret extends StatefulWidget {
  const _BlinkingCaret();

  @override
  State<_BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<_BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _c,
      child: Container(
        width: 2,
        height: 18,
        margin: const EdgeInsets.only(left: 1),
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
      ),
    );
  }
}

class _EndOfChapter extends StatelessWidget {
  const _EndOfChapter({
    this.showNav = true,
    this.onReplay,
    this.onNext,
    this.onPrev,
  });
  final bool showNav;
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
          if (showNav) ...[
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
