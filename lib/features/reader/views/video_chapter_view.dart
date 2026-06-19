import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../../../core/markdown/markdown.dart';

/// Video chapter view: YouTube player + optional markdown caption.
///
/// Plan §4.5 — uses `youtube_player_flutter` (now wired in pubspec).
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
      _controller = YoutubePlayerController(
        initialVideoId: widget.videoId,
        flags: const YoutubePlayerFlags(
          autoPlay: false,
          mute: false,
          enableCaption: true,
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return YoutubePlayerBuilder(
      player: YoutubePlayer(
        controller: _controller!,
        showVideoProgressIndicator: true,
        progressIndicatorColor: const Color(0xFFE11D48),
        progressColors: const ProgressBarColors(
          playedColor: Color(0xFFE11D48),
          handleColor: Color(0xFFB91C1C),
        ),
      ),
      builder: (context, player) {
        return ListView(
          controller: widget.scrollController,
          padding: const EdgeInsets.all(16),
          children: [
            if (_controller != null) ...[
              player,
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
      },
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
