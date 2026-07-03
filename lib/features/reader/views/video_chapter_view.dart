import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../../../core/markdown/markdown.dart';

/// Video chapter view: YouTube player with default controls + optional
/// markdown caption.
///
/// Uses `youtube_player_flutter` v10 with `showControls: true` so
/// YouTube's native iframe controls are visible. The v10 widget also
/// renders its own custom overlay — we disable that overlay by using
/// the `builder` to return only the raw player surface (no custom
/// controls). This gives the user a single, familiar YouTube control
/// bar (play/pause/seek/fullscreen/volume) — the same UX as watching
/// on youtube.com.
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

  /// YouTube video IDs are exactly 11 characters from `[A-Za-z0-9_-]`.
  /// Validate before passing to the controller — a compromised backend
  /// could return a malformed ID that constructs a non-YouTube URL.
  static final RegExp _youtubeIdRe = RegExp(r'^[A-Za-z0-9_-]{11}$');

  @override
  void initState() {
    super.initState();
    if (widget.videoId.isNotEmpty && _youtubeIdRe.hasMatch(widget.videoId)) {
      _controller = YoutubePlayerController.fromVideoId(
        videoId: widget.videoId,
        params: const YoutubePlayerParams(
          showControls: true, // YouTube native controls ON
          showFullscreenButton: true,
          mute: false,
          enableCaption: true,
        ),
      );
    }
  }

  @override
  void dispose() {
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
              autoFullScreen: true,
              enableFullScreenOnVerticalDrag: true,
              // Return only the raw player surface — no custom overlay.
              // YouTube iframe native controls are sufficient.
              builder: (context, player, controller) => player,
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
