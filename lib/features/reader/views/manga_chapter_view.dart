import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../../../models/chapter_content.dart';

/// Manga chapter view: vertical list of cover-fit images, tap any image
/// to open a pinch-to-zoom gallery. Plan §4.5 + §5.4.
///
/// When [localImagePaths] is non-empty, the view prefers the local
/// file path for each image (used by the offline reader). For images
/// without a local mapping, it falls back to `CachedNetworkImage`,
/// which may still hit the OS disk cache if the image was viewed
/// online before.
///
/// Layout stability: each page reserves its REAL aspect ratio before
/// the pixels arrive — [MangaPage.width]/[MangaPage.height] from the
/// server when available, otherwise the size is decoded on the fly and
/// cached for the session. Without this, a fixed-height placeholder
/// (240px) was replaced by the image's real height at load time and
/// every page below it jumped — with many pages loading concurrently
/// the list reflowed chaotically. A fixed 3:4 ratio was tried before
/// but distorted non-3:4 pages; the real ratio avoids both problems.
class MangaChapterView extends StatelessWidget {
  const MangaChapterView({
    super.key,
    required this.pages,
    this.scrollController,
    this.localImagePaths = const {},
  });

  final List<MangaPage> pages;
  final ScrollController? scrollController;

  /// Map of `imageUrl → localFilePath`. When an image's URL is in
  /// this map, the view renders it from the local file instead of
  /// the network. Used by the offline reader.
  final Map<String, String> localImagePaths;

  @override
  Widget build(BuildContext context) {
    if (pages.isEmpty) {
      return const Center(child: Text('Chương này không có ảnh.'));
    }
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: pages.length,
      itemBuilder: (context, i) {
        final page = pages[i];
        return GestureDetector(
          onTap: () => _openGallery(context, i),
          child: _MangaPageImage(
            page: page,
            localPath: localImagePaths[page.url],
          ),
        );
      },
    );
  }

  void _openGallery(BuildContext context, int initialIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _MangaGallery(
          pages: pages,
          localImagePaths: localImagePaths,
          initialIndex: initialIndex,
        ),
      ),
    );
  }
}

/// Fullscreen pinch-to-zoom gallery. StatefulWidget để sở hữu (và
/// dispose) PageController — trước đây controller được tạo inline trong
/// route builder và không bao giờ dispose → leak mỗi lần mở gallery.
class _MangaGallery extends StatefulWidget {
  const _MangaGallery({
    required this.pages,
    required this.localImagePaths,
    required this.initialIndex,
  });

  final List<MangaPage> pages;
  final Map<String, String> localImagePaths;
  final int initialIndex;

  @override
  State<_MangaGallery> createState() => _MangaGalleryState();
}

class _MangaGalleryState extends State<_MangaGallery> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  ImageProvider _resolveProvider(int i) {
    final url = widget.pages[i].url;
    final localPath = widget.localImagePaths[url];
    if (localPath != null && File(localPath).existsSync()) {
      return FileImage(File(localPath));
    }
    return CachedNetworkImageProvider(url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PhotoViewGallery.builder(
            backgroundDecoration: const BoxDecoration(color: Colors.black),
            itemCount: widget.pages.length,
            pageController: _pageController,
            builder: (_, i) {
              return PhotoViewGalleryPageOptions(
                imageProvider: _resolveProvider(i),
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.covered * 2,
              );
            },
          ),
          Positioned(
            top: 16,
            right: 16,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

/// One manga page in the reading list.
///
/// Reserves the page's real aspect ratio BEFORE the image bytes arrive
/// so the ListView never reflows underneath the reader:
///
/// 1. [MangaPage.width]/[MangaPage.height] from the server (the
///    preferred path — exact ratio, zero work on device).
/// 2. A session-level cache of sizes decoded from the same
///    `ImageProvider` used to render (so re-visiting a chapter or
///    scrolling back is already stable).
/// 3. On-the-fly decoding (fallback for legacy rows / GIFs / old
///    offline downloads). The provider is resolved once and the
///    decoded frame is reused by the render — no double download.
///
/// While the ratio is unknown the tile keeps a fixed-height loading
/// box; once known it swaps to `AspectRatio(real)` and the image is
/// laid out at exactly the reserved size — no jump, no distortion.
class _MangaPageImage extends StatefulWidget {
  const _MangaPageImage({required this.page, this.localPath});

  final MangaPage page;
  final String? localPath;

  @override
  State<_MangaPageImage> createState() => _MangaPageImageState();
}

class _MangaPageImageState extends State<_MangaPageImage> {
  /// Session-wide `imageUrl → decoded Size`, shared across chapters so
  /// pages seen before keep their reserved ratio instantly.
  static final Map<String, Size> _sizeCache = {};

  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _decodedSize;

  double? get _aspectRatio {
    final w = widget.page.width;
    final h = widget.page.height;
    if (w != null && h != null && w > 0 && h > 0) return w / h;
    final cached = _sizeCache[widget.page.url];
    if (cached != null) return cached.width / cached.height;
    final decoded = _decodedSize;
    if (decoded != null) return decoded.width / decoded.height;
    return null;
  }

  ImageProvider _provider() {
    final localPath = widget.localPath;
    if (localPath != null && File(localPath).existsSync()) {
      return FileImage(File(localPath));
    }
    return CachedNetworkImageProvider(widget.page.url);
  }

  @override
  void initState() {
    super.initState();
    if (_aspectRatio == null) _decodeDimensions();
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener!);
    super.dispose();
  }

  /// Resolve the provider just to learn the pixel size. The decoded
  /// frame lands in Flutter's image cache keyed by the same provider
  /// (FileImage/`CachedNetworkImageProvider` compare by path/URL), so
  /// the render below reuses it — no extra network round trip.
  void _decodeDimensions() {
    final stream = _provider().resolve(ImageConfiguration.empty);
    _stream = stream;
    _listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        final size = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        _sizeCache[widget.page.url] = size;
        setState(() => _decodedSize = size);
      },
      onError: (_, _) {},
    );
    stream.addListener(_listener!);
  }

  Widget _buildImage() {
    final localPath = widget.localPath;
    if (localPath != null && File(localPath).existsSync()) {
      // Local file exists — render directly from disk. No network
      // needed, no cache lookup, no placeholder flicker.
      return Image.file(
        File(localPath),
        fit: BoxFit.fitWidth,
        errorBuilder: (_, _, _) => _buildNetworkFallback(),
      );
    }
    return CachedNetworkImage(
      imageUrl: widget.page.url,
      fit: BoxFit.fitWidth,
      placeholder: (_, _) => const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
      errorWidget: (_, _, _) => const SizedBox(
        height: 200,
        child: Center(child: Icon(Icons.broken_image_outlined, size: 36)),
      ),
    );
  }

  Widget _buildNetworkFallback() {
    return CachedNetworkImage(
      imageUrl: widget.page.url,
      fit: BoxFit.fitWidth,
      placeholder: (_, _) => const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
      errorWidget: (_, _, _) => const SizedBox(
        height: 200,
        child: Center(child: Icon(Icons.broken_image_outlined, size: 36)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ratio = _aspectRatio;
    if (ratio != null) {
      return AspectRatio(aspectRatio: ratio, child: _buildImage());
    }
    // Ratio unknown yet (dimensions still decoding / bytes on the
    // wire). Fixed-height box → swap to the real AspectRatio the
    // moment the size is known. No content below shifts after that.
    return const SizedBox(
      height: 240,
      child: Center(child: CircularProgressIndicator()),
    );
  }
}
