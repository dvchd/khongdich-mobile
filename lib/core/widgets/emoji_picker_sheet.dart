import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/emoji_service.dart';

/// Opens the emoji picker bottom sheet and returns the selected
/// shortcode (e.g. `:khongdich:`) — or null when dismissed. Callers
/// insert the result into their text field at the cursor.
Future<String?> showEmojiPickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _EmojiPickerSheet(),
  );
}

class _EmojiPickerSheet extends ConsumerStatefulWidget {
  const _EmojiPickerSheet();

  @override
  ConsumerState<_EmojiPickerSheet> createState() => _EmojiPickerSheetState();
}

class _EmojiPickerSheetState extends ConsumerState<_EmojiPickerSheet> {
  final TextEditingController _search = TextEditingController();
  EmojiFeed? _feed;
  List<EmojiItem> _searchResults = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _popularOffset = 0;
  // Search debounce + stale-response guard: mỗi ký tự trước đây fire 1
  // request, response cũ về sau ghi đè kết quả mới (out-of-order).
  Timer? _searchDebounce;
  int _searchRequestId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final service = ref.read(emojiServiceProvider);
    try {
      final feed = await service.loadFeed();
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _hasMore = feed.hasMore;
        _popularOffset = feed.popular.length;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearch(String q) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_runSearch(q));
    });
  }

  Future<void> _runSearch(String q) async {
    final trimmed = q.trim();
    if (trimmed.isEmpty) {
      _searchRequestId++;
      if (mounted) setState(() => _searchResults = []);
      return;
    }
    final requestId = ++_searchRequestId;
    final results = await ref.read(emojiServiceProvider).search(trimmed);
    if (!mounted || requestId != _searchRequestId) return;
    setState(() => _searchResults = results);
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    final more = await ref
        .read(emojiServiceProvider)
        .loadMorePopular(_popularOffset);
    if (!mounted) return;
    final feed = ref.read(emojiServiceProvider).feed;
    setState(() {
      _feed = feed;
      _hasMore = feed?.hasMore ?? false;
      _popularOffset += more.length;
      _loadingMore = false;
    });
  }

  void _pick(String name) => Navigator.of(context).pop(':$name:');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Khi bàn phím hiện (gõ vào ô tìm emoji), sheet phải thu lại phía trên
    // bàn phím — trước đây height cố định 60% màn hình + bàn phím che mất
    // phần dưới grid (không cuộn tới, không chạm được "xem thêm").
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final height = math.min(screenHeight * 0.6, screenHeight - viewInsets - 48);
    return SizedBox(
      height: height < 200 ? 200 : height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: _onSearch,
              decoration: InputDecoration(
                hintText: 'Tìm emoji…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _search.text.trim().isNotEmpty
                ? _EmojiGrid(
                    items: _searchResults,
                    emptyHint: 'Không tìm thấy emoji nào.',
                    onPick: _pick,
                  )
                : ListView(
                    children: [
                      if ((_feed?.featured ?? const []).isNotEmpty) ...[
                        _SectionLabel(
                          icon: Icons.star,
                          label: 'Nổi bật',
                          color: theme.colorScheme.tertiary,
                        ),
                        _EmojiGrid(
                          items: _feed!.featured,
                          onPick: _pick,
                          height: 48,
                        ),
                      ],
                      if ((_feed?.recent ?? const []).isNotEmpty) ...[
                        _SectionLabel(
                          icon: Icons.schedule,
                          label: 'Gần đây',
                          color: theme.colorScheme.primary,
                        ),
                        _EmojiGrid(
                          items: _feed!.recent,
                          onPick: _pick,
                          height: 48,
                        ),
                      ],
                      if ((_feed?.mine ?? const []).isNotEmpty) ...[
                        _SectionLabel(
                          icon: Icons.person,
                          label: 'Của tôi',
                          color: theme.colorScheme.secondary,
                        ),
                        _EmojiGrid(
                          items: _feed!.mine,
                          onPick: _pick,
                          height: 48,
                        ),
                      ],
                      _SectionLabel(
                        icon: Icons.whatshot,
                        label: 'Phổ biến',
                        color: Colors.orangeAccent,
                      ),
                      _EmojiGrid(
                        items: _feed?.popular ?? const [],
                        onPick: _pick,
                        height: 48,
                      ),
                      if (_hasMore)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Center(
                            child: _loadingMore
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : TextButton.icon(
                                    onPressed: _loadMore,
                                    icon: const Icon(Icons.expand_more),
                                    label: const Text('Xem thêm'),
                                  ),
                          ),
                        ),
                      const SizedBox(height: 16),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmojiGrid extends StatelessWidget {
  const _EmojiGrid({
    required this.items,
    required this.onPick,
    this.height = 48,
    this.emptyHint,
  });

  final List<EmojiItem> items;
  final void Function(String name) onPick;
  final double height;
  final String? emptyHint;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      if (emptyHint == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            emptyHint!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final e = items[i];
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onPick(e.name),
          child: Tooltip(
            message: ':${e.name}:',
            child: Image.network(
              e.imageUrl,
              width: 28,
              height: 28,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(
                Icons.broken_image_outlined,
                size: 24,
              ),
            ),
          ),
        );
      },
    );
  }
}
