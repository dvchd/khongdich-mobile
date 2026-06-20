import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../../../core/markdown/markdown.dart';

/// Video chapter view: YouTube player + optional markdown caption.
///
/// Uses `youtube_player_flutter` v10 which renders its own custom
/// controls overlay (not YouTube's native iframe controls). We use
/// the `builder` parameter to provide a minimal overlay — just a
/// center play/pause button — instead of the default full controls
/// bar which caused the "duplicate controls" issue.
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
  PlayerState _playerState = PlayerState.unknown;

  @override
  void initState() {
    super.initState();
    if (widget.videoId.isNotEmpty) {
      _controller = YoutubePlayerController.fromVideoId(
        videoId: widget.videoId,
        params: const YoutubePlayerParams(
          showControls: false,
          showFullscreenButton: false,
          mute: false,
          enableCaption: true,
        ),
      );
      _controller!.listen((value) {
        if (mounted) {
          setState(() {
            _playerState = value.playerState;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _controller?.close();
    super.dispose();
  }

  void _togglePlay() {
    if (_controller == null) return;
    if (_playerState == PlayerState.playing) {
      _controller!.pauseVideo();
    } else {
      _controller!.playVideo();
    }
  }

  void _enterFullscreen() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: YoutubePlayer(
                controller: _controller!,
                aspectRatio: 16 / 9,
                // Use builder to provide a MINIMAL overlay: just a
                // center play/pause button + a fullscreen button in
                // the corner. No duplicate progress bar, no duplicate
                // controls row.
                builder: (context, player, controller) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      player,
                      // Center play/pause button — only show when not
                      // playing (auto-hides during playback).
                      if (_playerState != PlayerState.playing &&
                          _playerState != PlayerState.buffering)
                        GestureDetector(
                          onTap: _togglePlay,
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.play_arrow,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ),
                      // Buffering indicator
                      if (_playerState == PlayerState.buffering)
                        const CircularProgressIndicator(color: Colors.white),
                      // Fullscreen button (top-right)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: IconButton(
                          icon: const Icon(Icons.fullscreen,
                              color: Colors.white, size: 20),
                          onPressed: _enterFullscreen,
                        ),
                      ),
                    ],
                  );
                },
              ),
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
