import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Cache manager dùng chung cho toàn bộ ảnh trong app.
///
/// Ảnh được serve từ CDN với URL **immutable** — mỗi ảnh có UUID riêng,
/// ảnh mới = URL mới, ảnh cũ không bao giờ đổi nội dung (xem
/// `api/upload.rs` backend: key dạng `uploads/<tháng>/<userId>/<uuid>`).
/// Do đó cache lâu dài hoàn toàn an toàn: không sợ ảnh stale, không cần
/// revalidate với server (CDN cũng để `Cache-Control` 1 năm).
///
/// Cấu hình "gần như vô hạn":
///   - `stalePeriod` 10 năm — file không bao giờ bị xóa vì "hết hạn".
///   - `maxNrOfCacheObjects` 20000 — van an toàn: ảnh manga ~100-400KB,
///     20000 ảnh ≈ 4-6GB ≈ 2 năm đọc tích cực. Ngăn disk phình vô hạn nếu
///     user không bao giờ dọn cache (vẫn có nút "Xoá cache ảnh" trong
///     Cài đặt để giải phóng thủ công).
///
/// Có thể nâng/giảm giới hạn tuỳ nhu cầu thực tế.
class AppImageCache {
  AppImageCache._();

  static final CacheManager instance = CacheManager(
    Config(
      'khongdichImageCache',
      stalePeriod: const Duration(days: 3650),
      maxNrOfCacheObjects: 20000,
    ),
  );
}