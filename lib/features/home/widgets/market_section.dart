import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/emoji_text.dart';
import '../../../models/market.dart';
import '../../../repositories/market_repository.dart';

/// Home "Chợ Phiên" section — mirrors the web home market section:
/// header with this week's Chủ Chợ, story grid, a preview of the latest
/// Họp Chợ messages, and a button into the realtime chat screen.
/// Hidden while the chợ is closed (same behaviour as the web).
class MarketHomeSection extends ConsumerWidget {
  const MarketHomeSection({super.key, required this.section});

  final MarketSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!section.open) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final master = section.masterName;
    final preview = section.messages.length > 4
        ? section.messages.sublist(section.messages.length - 4)
        : section.messages;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.push('/market'),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '🛒 Chợ Phiên',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    if (master != null)
                      Flexible(
                        child: Text(
                          'chủ chợ: $master',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: scheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (section.stories.isNotEmpty)
                  SizedBox(
                    height: 100,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: section.stories.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (context, i) {
                        final s = section.stories[i];
                        return SizedBox(
                          width: 70,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => context.push('/story/${s.slug}'),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: s.coverUrl == null
                                        ? Container(
                                            color: AppTheme.primary.withValues(
                                              alpha: 0.15,
                                            ),
                                            child: const Icon(
                                              Icons.book,
                                              size: 28,
                                            ),
                                          )
                                        : Image.network(
                                            s.coverUrl!,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                Container(
                                                  color: AppTheme.primary
                                                      .withValues(alpha: 0.15),
                                                  child: const Icon(
                                                    Icons.book,
                                                    size: 28,
                                                  ),
                                                ),
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  s.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (section.stories.isNotEmpty) const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      '💬 Họp Chợ',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'chat realtime với tác giả',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (preview.isEmpty)
                  Text(
                    'Chưa có tin nhắn nào. Hãy mở màn!',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                for (final m in preview)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${m.displayName.isEmpty ? m.username : m.displayName}: ',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Expanded(
                          child: EmojiText(
                            text: m.content,
                            contentHtml: m.contentHtml,
                            style: theme.textTheme.bodySmall?.copyWith(
                              height: 1.3,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => context.push('/market'),
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                    label: const Text('Vào Họp Chợ'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Best-effort market section for the home feed — errors (offline,
/// endpoint down) silently hide the section instead of failing home.
final homeMarketProvider = FutureProvider<MarketSection?>((ref) async {
  try {
    final repo = ref.watch(marketRepositoryProvider);
    final section = await repo.fetchSection();
    return section.open ? section : null;
  } catch (_) {
    return null;
  }
});
