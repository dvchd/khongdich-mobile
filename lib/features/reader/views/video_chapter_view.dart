import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../../../core/markdown/markdown.dart';

/// Video chapter view: YouTube player + optional markdown caption.
///
/// Uses `youtube_player_flutter` v10. The player widget renders its
/// own controls overlay — we don't add a second set.
///
/// Fullscreen: when the user taps the fullscreen button, we force
/// landscape orientation. On exit, we restore portrait.
class VideoChapterView extends StatefulWidget {
  const VideoChapterView({
    super.key,
    required this.videoId,
    this.captionMarkdown,
    required this.readerTheme,
    this.scrollController,
  });

  final String videoId;
  final String? captionMarkdown;
  final ReaderTheme readerTheme;
  final ScrollController? scrollController;

  @override
  State<VideoChapterView> createState() => _VideoChapterViewState();
}

class _VideoChapterViewState extends State<VideoChapterView> {
  YoutubePlayerController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.videoId.isNotEmpty) {
      _controller = YoutubePlayerController.fromVideoId(
        videoId: widget.videoId,
        params: const YoutubePlayerParams(
          showControls: true,
          showFullscreenButton: true,
          mute: false,
          enableCaption: true,
        ),
      );
    }
  }

  @override
  void dispose() {
    // Restore portrait when leaving the video view.
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _controller?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        if (_controller != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: YoutubePlayer(
              controller: _controller!,
              aspectRatio: 16 / 9,
              // Enable auto-fullscreen on vertical drag (user swipes up
              // → fullscreen landscape).
              autoFullScreen: true,
              enableFullScreenOnVerticalDrag: true,
            ),
          ),
          const SizedBox(height: 16),
        ] else
          const _VideoPlaceholder(
            message: 'Không nhận dạng được video. Hãy mở trên web.',
          ),
        if (widget.captionMarkdown != null &&
            widget.captionMarkdown!.isNotEmpty) ...[
          const SizedBox(height: 8),
          MarkdownRenderer(
            blocks: MarkdownParser().parse(widget.captionMarkdown!),
            theme: widget.readerTheme,
          ),
        ],
      ],
    );
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, color: Colors.white70, size: 48),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
