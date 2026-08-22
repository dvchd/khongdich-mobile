import 'package:flutter/material.dart';

import '../../../models/story.dart';
import '../widgets/story_card.dart';

/// Horizontal-scroll section used on the home screen.
///
/// The section header carries a small tinted icon emblem + title (calm
/// Material style, matching the rest of the app), and the rail height
/// leaves room for both cover + title + author so nothing clips.
///
/// [onReload] renders a compact reload icon right after the title — dùng
/// cho các section có thể "roll lại" (vd. Truyện ngẫu nhiên — gieo xúc
/// xắc với seed mới, hoặc Hoàn thành — refetch). Khi truyền [reloadIcon]/
/// [reloadTooltip] khác, nút đổi icon/tooltip theo ngữ cảnh.
class StorySection extends StatelessWidget {
  const StorySection({
    super.key,
    required this.title,
    required this.items,
    this.icon,
    this.trailing,
    this.height = 276,
    this.cardWidth = 136,
    this.onReload,
    this.reloadIcon = Icons.refresh,
    this.reloadTooltip = 'Làm mới',
  });

  final String title;

  /// Section emblem shown in the tinted rounded square (Material icon).
  final IconData? icon;
  final String? trailing;
  final double height;

  /// Chiều rộng mỗi card trong rail — tăng từ 120 để bìa trên trang chủ
  /// lớn hơn, gần bằng bìa trong tủ truyện (grid 2 cột) thay vì "nhỏ hơn
  /// hẳn" như trước.
  final double cardWidth;
  final VoidCallback? onReload;
  final IconData reloadIcon;
  final String reloadTooltip;
  final List<StoryCard> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 16, color: scheme.primary),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.1,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (onReload != null)
                IconButton(
                  icon: Icon(reloadIcon, size: 18),
                  tooltip: reloadTooltip,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: onReload,
                ),
              if (trailing != null)
                Text(
                  trailing!,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, i) => SizedBox(
              width: cardWidth,
              child: items[i],
            ),
          ),
        ),
      ],
    );
  }
}

/// Convenience alias — StorySection takes pre-built cards so we can pass
/// per-item callbacks. This small wrapper exists for the few callers that
/// prefer (story, onTap) tuples.
StoryCard buildCard(StorySummary story, VoidCallback onTap, {String? badge}) {
  return StoryCard(story: story, onTap: onTap, badge: badge);
}