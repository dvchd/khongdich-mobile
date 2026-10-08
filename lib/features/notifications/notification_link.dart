/// Parsed deep link từ thông báo (backend lưu dạng tương đối, ví dụ
/// `/truyen/{slug}/chuong/{n}#comment-{id}` — cùng contract với web).
///
/// Các dạng backend phát ra:
/// - `/truyen/{slug}` — chi tiết truyện
/// - `/truyen/{slug}/chuong/{n}` — chương mới (new_chapter...)
/// - `/truyen/{slug}#comment-{id}` — bình luận truyện
/// - `/truyen/{slug}/chuong/{n}#comment-{id}` — bình luận chương/đoạn
/// - `/truyen/{slug}#reviews` — đánh giá mới
/// - `/truyen/{slug}/chuong/{n}#seg-{paraKey}` — góp ý đoạn (chỉ lấy chương)
library;

class NotificationLink {
  const NotificationLink({
    required this.slug,
    this.chapterNumber,
    this.commentId,
    this.isReviews = false,
  });

  /// Slug truyện (khác id backend — cần resolve qua API khi cần id).
  final String slug;

  /// Số chương nếu link trỏ vào một chương.
  final int? chapterNumber;

  /// UUID bình luận nếu link có fragment `#comment-{id}`.
  final String? commentId;

  /// True khi link có fragment `#reviews` (đánh giá truyện).
  final bool isReviews;

  /// Parse link; trả null khi không phải link truyện (vd bài viết
  /// `/cong-nghe-viet/...` — app chưa có màn tương ứng).
  static NotificationLink? parse(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    final segments = uri.pathSegments;
    if (segments.length < 2 || segments[0] != 'truyen') return null;
    final slug = segments[1];
    if (slug.isEmpty) return null;

    int? chapterNumber;
    if (segments.length >= 4 && segments[2] == 'chuong') {
      chapterNumber = int.tryParse(segments[3]);
    }

    String? commentId;
    var isReviews = false;
    final fragment = uri.fragment;
    if (fragment.startsWith('comment-')) {
      final id = fragment.substring('comment-'.length);
      if (id.isNotEmpty) commentId = id;
    } else if (fragment == 'reviews') {
      isReviews = true;
    }

    return NotificationLink(
      slug: slug,
      chapterNumber: chapterNumber,
      commentId: commentId,
      isReviews: isReviews,
    );
  }
}
