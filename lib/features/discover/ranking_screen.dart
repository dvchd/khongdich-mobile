import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/story.dart';
import '../../repositories/story_repository.dart';
import '../home/widgets/story_card.dart';
/// BXH truyện — đối chiếu trang web `/bxh`. Tabs theo kỳ (Hôm nay /
/// Tuần / Tháng / Toàn bộ) + tab VIP riêng.
class RankingScreen extends ConsumerStatefulWidget {
  const RankingScreen({super.key});

  @override
  ConsumerState<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends ConsumerState<RankingScreen> {
  static const _periods = [
    ('day', 'Hôm nay'),
    ('week', 'Tuần'),
    ('month', 'Tháng'),
    ('all', 'Toàn bộ'),
  ];

  String _period = 'week';
  bool _vip = false;
  bool _loading = true;
  String? _error;
  List<StorySummary> _stories = [];

  StoryRepository get _repo => ref.read(storyRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stories = _vip
          ? await _repo.fetchRankingVip(period: _period)
          : (await _repo.fetchRanking(period: _period)).stories;
      if (!mounted) return;
      setState(() {
        _stories = stories;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BXH')),
      body: Column(
        children: [
          // Kỳ tabs
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<String>(
                    segments: [
                      for (final (value, label) in _periods)
                        ButtonSegment(value: value, label: Text(label)),
                    ],
                    selected: {_period},
                    onSelectionChanged: _loading
                        ? null
                        : (s) {
                            setState(() => _period = s.first);
                            _load();
                          },
                  ),
                ),
              ],
            ),
          ),
          // VIP toggle
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: FilterChip(
                avatar: const Icon(Icons.workspace_premium,
                    size: 15, color: Color(0xFFD97706)),
                label: const Text('Truyện VIP'),
                selected: _vip,
                onSelected: _loading
                    ? null
                    : (sel) {
                        setState(() => _vip = sel);
                        _load();
                      },
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              const Text('Không tải được BXH'),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Thử lại')),
            ],
          ),
        ),
      );
    }
    if (_stories.isEmpty) {
      return const Center(child: Text('Chưa có dữ liệu cho kỳ này.'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 14,
          crossAxisSpacing: 12,
          childAspectRatio: 0.46,
        ),
        itemCount: _stories.length,
        itemBuilder: (context, i) {
          final s = _stories[i];
          return Stack(
            children: [
              StoryCard(
                story: s,
                onTap: () => context.push('/story/${s.slug}'),
              ),
              // Hạng — góc trái trên bìa.
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: i < 3
                        ? const Color(0xFFF59E0B)
                        : Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '#${i + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}