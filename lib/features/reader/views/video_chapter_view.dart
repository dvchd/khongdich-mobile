import 'package:flutter/material.dart';

import '../../../core/markdown/markdown.dart';

/// Video chapter view: YouTube player + optional markdown caption.
///
/// Plan §4.5 — for the MVP build we render a clean placeholder instead of
/// an actual YouTube player. The `youtube_player_flutter` dependency is
/// commented out in `pubspec.yaml`; uncomment + wire the controller here
/// once the Firebase / video pipeline lands.
class VideoChapterView extends StatelessWidget {
  const VideoChapterView({
    super.key,
    required this.videoId,
    this.captionMarkdown,
    required this.readerTheme,
  });

  final String videoId;
  final String? captionMarkdown;
  final ReaderTheme readerTheme;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_circle_outline, color: Colors.white, size: 64),
                  SizedBox(height: 8),
                  Text(
                    'Trình phát YouTube sẽ được bật khi Phase 2 hoàn tất.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (captionMarkdown != null && captionMarkdown!.isNotEmpty) ...[
          const SizedBox(height: 24),
          MarkdownRenderer(
            blocks: MarkdownParser().parse(captionMarkdown!),
            theme: readerTheme,
          ),
        ],
      ],
    );
  }
}
