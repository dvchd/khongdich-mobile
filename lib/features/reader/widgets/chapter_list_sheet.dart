import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';

/// One row in the shared [ChapterListSheet].
///
/// Both the online reader (which fetches chapters from the API) and
/// the offline reader (which loads chapters from local Drift) build
/// a list of [ChapterListEntry] and pass it to [ChapterListSheet].
/// The sheet itself doesn't care where the data came from — it just
/// renders the list and fires [onSelect] with the chosen chapter
/// number.
class ChapterListEntry {
  const ChapterListEntry({
    required this.number,
    required this.title,
  });
  final int number;
  final String title;
}

/// Bottom sheet listing chapters in the current story.
///
/// Shared by the online and offline readers. The parent screen
/// supplies the entries (from API or Drift) and an `onSelect`
/// callback that performs the navigation appropriate for its data
/// source (online → `/chapter/$storyId:$number`, offline →
/// `/chapter-offline/$chapterId`).
///
/// The current chapter is highlighted with [AppTheme.primary] and a
/// check-circle icon.
class ChapterListSheet extends ConsumerWidget {
  const ChapterListSheet({
    super.key,
    required this.entries,
    required this.currentChapter,
    required this.onSelect,
  });

  final List<ChapterListEntry> entries;
  final int currentChapter;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text('Danh sách chương',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('Chưa có chương nào.'))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: entries.length,
                        itemBuilder: (_, i) {
                          final e = entries[i];
                          final isCurrent = e.number == currentChapter;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: isCurrent
                                  ? AppTheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                              child: Text(
                                '${e.number}',
                                style: TextStyle(
                                  color: isCurrent
                                      ? Colors.white
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                ),
                              ),
                            ),
                            title: Text(
                              e.title.isEmpty
                                  ? 'Chương ${e.number}'
                                  : e.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: isCurrent
                                  ? TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.primary,
                                    )
                                  : null,
                            ),
                            trailing: isCurrent
                                ? const Icon(Icons.check_circle,
                                    color: AppTheme.primary, size: 20)
                                : null,
                            onTap: () {
                              Navigator.of(context).pop();
                              onSelect(e.number);
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
