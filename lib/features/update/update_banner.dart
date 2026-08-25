import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_update_provider.dart';

/// Banner cập nhật trên Trang chủ — chỉ hiện khi CH Play có bản mới
/// (phase available/downloading/readyToInstall và user chưa "Để sau").
///
/// Style khớp các card khác của Home (Material surfaceContainerLow,
/// radius 16 như MarketHomeSection).
class AppUpdateBanner extends ConsumerWidget {
  const AppUpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateProvider);
    if (!state.showBanner) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Nội dung theo phase: mời tải → đang tải → mời cài.
    final (
      IconData? icon,
      String title,
      String subtitle,
      List<Widget> actions,
    ) = switch (state.phase) {
      AppUpdatePhase.available => (
        Icons.system_update_alt,
        'Có phiên bản mới',
        'Cập nhật để nhận tính năng và bản sửa lỗi mới nhất.',
        [
          TextButton(
            onPressed: () => ref.read(appUpdateProvider.notifier).dismiss(),
            child: const Text('Để sau'),
          ),
          FilledButton(
            onPressed: () =>
                ref.read(appUpdateProvider.notifier).startDownload(),
            child: const Text('Cập nhật'),
          ),
        ],
      ),
      AppUpdatePhase.downloading => (
        Icons.downloading,
        'Đang tải bản cập nhật…',
        'Bạn vẫn dùng app bình thường trong lúc tải.',
        <Widget>[],
      ),
      AppUpdatePhase.readyToInstall => (
        Icons.task_alt,
        'Bản cập nhật đã sẵn sàng',
        'Cài ngay để khởi động lại vào phiên bản mới.',
        [
          FilledButton(
            onPressed: () =>
                ref.read(appUpdateProvider.notifier).installDownloaded(),
            child: const Text('Cài ngay'),
          ),
        ],
      ),
      AppUpdatePhase.idle => (null, '', '', <Widget>[]), // không xảy ra
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 22, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              if (state.phase == AppUpdatePhase.downloading) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: const LinearProgressIndicator(minHeight: 4),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
