import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

/// Manga chapter view: vertical list of cover-fit images, tap any image
/// to open a pinch-to-zoom gallery. Plan §4.5 + §5.4.
class MangaChapterView extends StatelessWidget {
  const MangaChapterView({super.key, required this.images});

  final List<String> images;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return const Center(child: Text('Chương này không có ảnh.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: images.length,
      itemBuilder: (context, i) {
        return GestureDetector(
          onTap: () => _openGallery(context, i),
          child: CachedNetworkImage(
            imageUrl: images[i],
            fit: BoxFit.fitWidth,
            placeholder: (_, __) => const SizedBox(
              height: 240,
              child: Center(child: CircularProgressIndicator()),
            ),
            errorWidget: (_, __, ___) => const SizedBox(
              height: 200,
              child: Center(child: Icon(Icons.broken_image_outlined, size: 36)),
            ),
          ),
        );
      },
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
                pageController:
                    PageController(initialPage: initialIndex),
                builder: (_, i) => PhotoViewGalleryPageOptions(
                  imageProvider: CachedNetworkImageProvider(images[i]),
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 2,
                ),
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
