import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/story.dart';
import '../../downloads/offline_library_screen.dart' show downloadedStoryIdsProvider;

/// Compact story tile used in home / search / bookshelf grids and lists.
///
/// Renders a green "downloaded" badge on the cover whenever the story
/// has at least one chapter stored in the local Drift DB. The badge is
/// story-level (not per-chapter) so it shows up consistently across
/// home, search, bookshelf and story-detail screens — exactly matching
/// the user's mental model of "I have this story offline".
class StoryCard extends ConsumerWidget {
  const StoryCard({
    super.key,
    required this.story,
    this.onTap,
    this.badge,
    /// When true, suppresses the auto-rendered downloaded badge.
    /// Used by screens that already convey download state in another
    /// way (e.g. the Downloaded tab in the bookshelf).
    this.hideDownloadedBadge = false,
  });

  final StorySummary story;
  final VoidCallback? onTap;
  final String? badge;
  final bool hideDownloadedBadge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadedIds = ref.watch(downloadedStoryIdsProvider);
    final isDownloaded = downloadedIds.contains(story.id);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cover dùng AspectRatio 2:3 (chuẩn bìa truyện) thay vì
            // Expanded — Expanded khiến cover bị co khi title/author dài,
            // làm các card cùng grid có chiều cao cover khác nhau.
            // AspectRatio cố định tỷ lệ → mọi cover đồng đều.
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: story.coverUrl == null || story.coverUrl!.isEmpty
                        ? Container(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            alignment: Alignment.center,
                            child: const Icon(Icons.book, size: 36),
                          )
                        : CachedNetworkImage(
                            imageUrl: story.coverUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, _) => Container(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                            ),
                            errorWidget: (_, _, _) => Container(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              alignment: Alignment.center,
                              child: const Icon(Icons.broken_image_outlined),
                            ),
                          ),
                  ),
                  if (badge != null)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          badge!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  // Story-level "downloaded" badge — top-left corner so
                  // it doesn't clash with the optional [badge] chip on
                  // the top-right.
                  if (isDownloaded && !hideDownloadedBadge)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.download_done,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  // VIP badge — top-right corner (below the optional
                  // [badge] chip which also uses top-right). We stack
                  // it below the badge chip so both can coexist.
                  if (story.isVip)
                    Positioned(
                      top: badge != null ? 28 : 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'VIP',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              story.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: 13,
                  ),
            ),
            if (story.author.isNotEmpty)
              Text(
                story.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}
