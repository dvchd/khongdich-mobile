import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bookshelf — 4 list types (reading / completed / plan_to_read / favorite).
/// Plan §5.6. For the MVP build we show the empty-state UI; the synced
/// bookmark store lands alongside the offline-reader / sync endpoint.
class BookshelfScreen extends ConsumerStatefulWidget {
  const BookshelfScreen({super.key});

  @override
  ConsumerState<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends ConsumerState<BookshelfScreen> {
  int _tab = 0;

  static const _tabs = [
    ('Đang đọc', Icons.menu_book),
    ('Đã đọc xong', Icons.check_circle_outline),
    ('Sẽ đọc', Icons.bookmark_outline),
    ('Yêu thích', Icons.favorite_outline),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tủ truyện')),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_tabs[i].$1),
                      avatar: Icon(_tabs[i].$2, size: 18),
                      selected: _tab == i,
                      onSelected: (_) => setState(() => _tab = i),
                    ),
                  ),
              ],
            ),
          ),
          const Expanded(
            child: _EmptyBookshelf(),
          ),
        ],
      ),
    );
  }
}

class _EmptyBookshelf extends StatelessWidget {
  const _EmptyBookshelf();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bookmark_border,
              size: 64,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          const Text('Chưa có truyện trong tủ.'),
          const SizedBox(height: 4),
          Text(
            'Đánh dấu truyện từ trang chi tiết để lưu vào đây.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
