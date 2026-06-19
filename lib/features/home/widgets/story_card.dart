import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../models/story.dart';

/// Compact story tile for the home / search / bookshelf grids.
class StoryCard extends StatelessWidget {
  const StoryCard({super.key, required this.story, this.onTap});

  final StorySummary story;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
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
                        placeholder: (_, __) => Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                        ),
                        errorWidget: (_, __, ___) => Container(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          alignment: Alignment.center,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              story.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: 14,
                  ),
            ),
            const SizedBox(height: 2),
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
