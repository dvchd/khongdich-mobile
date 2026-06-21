import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

/// Manga chapter view: vertical list of cover-fit images, tap any image
/// to open a pinch-to-zoom gallery. Plan §4.5 + §5.4.
///
/// When [localImagePaths] is non-empty, the view prefers the local
/// file path for each image (used by the offline reader). For images
/// without a local mapping, it falls back to `CachedNetworkImage`,
/// which may still hit the OS disk cache if the image was viewed
/// online before.
class MangaChapterView extends StatelessWidget {
  const MangaChapterView({
    super.key,
    required this.images,
    this.scrollController,
    this.localImagePaths = const {},
  });

  final List<String> images;
  final ScrollController? scrollController;

  /// Map of `imageUrl → localFilePath`. When an image's URL is in
  /// this map, the view renders it from the local file instead of
  /// the network. Used by the offline reader.
  final Map<String, String> localImagePaths;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return const Center(child: Text('Chương này không có ảnh.'));
    }
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: images.length,
      itemBuilder: (context, i) {
        return GestureDetector(
          onTap: () => _openGallery(context, i),
          child: _buildImage(images[i]),
        );
      },
    );
  }

  Widget _buildImage(String url) {
    final localPath = localImagePaths[url];
    if (localPath != null && File(localPath).existsSync()) {
      // Local file exists — render directly from disk. No network
      // needed, no cache lookup, no placeholder flicker.
      return Image.file(
        File(localPath),
        fit: BoxFit.fitWidth,
        errorBuilder: (_, _, _) => _buildNetworkFallback(url),
      );
    }
    return _buildNetworkFallback(url);
  }

  Widget _buildNetworkFallback(String url) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.fitWidth,
      placeholder: (_, _) => const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      ),
      errorWidget: (_, _, _) => const SizedBox(
        height: 200,
        child: Center(child: Icon(Icons.broken_image_outlined, size: 36)),
      ),
    );
  }

  void _openGallery(BuildContext context, int initialIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              PhotoViewGallery.builder(
                backgroundDecoration: const BoxDecoration(color: Colors.black),
                itemCount: images.length,
                pageController: PageController(initialPage: initialIndex),
                builder: (_, i) {
                  final url = images[i];
                  final localPath = localImagePaths[url];
                  final ImageProvider imageProvider;
                  if (localPath != null && File(localPath).existsSync()) {
                    imageProvider = FileImage(File(localPath));
                  } else {
                    imageProvider = CachedNetworkImageProvider(url);
                  }
                  return PhotoViewGalleryPageOptions(
                    imageProvider: imageProvider,
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
        ),
      ),
    );
  }
}
