import 'package:flutter/material.dart';

import '../../../models/story.dart';
import '../widgets/story_card.dart';

/// Horizontal-scroll section used on the home screen.
class StorySection extends StatelessWidget {
  const StorySection({
    super.key,
    required this.title,
    required this.items,
    this.height = 220,
  });

  final String title;
  final double height;
  final List<StoryCard> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
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
              width: 120,
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
