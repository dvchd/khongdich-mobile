import 'package:flutter/material.dart';

/// Trạng thái "không tải được" thân thiện + nút Thử lại — dùng cho các
/// màn hình khi offline / API 5xx (search, story detail, danh sách
/// chương...). Trước đây mỗi nơi tự viết một bản, nơi thì hiện nguyên
/// lỗi thô (DioException...) không có nút tải lại.
///
/// [message] = dòng tiêu đề thân thiện (vd. "Không tải được truyện."),
/// [detail] = nguyên nhân kỹ thuật hiện NHỎ + mờ phía dưới (vẫn hữu ích
/// khi debug, không gây rối mắt).
class AppRetryView extends StatelessWidget {
  const AppRetryView({
    super.key,
    required this.message,
    this.detail,
    required this.onRetry,
    this.icon = Icons.cloud_off,
    this.retryLabel = 'Thử lại',
    this.secondaryLabel,
    this.onSecondary,
  });

  final String message;
  final String? detail;
  final VoidCallback onRetry;
  final IconData icon;
  final String retryLabel;

  /// Hành động phụ (vd. "Về trang truyện") hiện dưới nút Thử lại — dùng
  /// khi màn lỗi cần lối thoát ngoài retry (access gate fail, ...).
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.onSurface.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(retryLabel),
            ),
            if (onSecondary != null) ...[
              const SizedBox(height: 4),
              TextButton(
                onPressed: onSecondary,
                child: Text(secondaryLabel ?? 'Quay lại'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
