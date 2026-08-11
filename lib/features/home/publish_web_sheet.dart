import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_client.dart';

/// Guidance sheet for publishing stories: the mobile app is read-only
/// (read + offline + TTS). Story publishing happens on the web.
///
/// Opens `<base_url>/dang-truyen` in the system browser (env-aware:
/// demo flavor → demo.khongdich.com, prod → khongdich.com).
class PublishWebSheet extends ConsumerWidget {
  const PublishWebSheet({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final base = ref.read(apiClientProvider).valueOrNull?.baseUrl ??
        'https://khongdich.com';
    final uri = Uri.parse('$base/dang-truyen');
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok && context.mounted) Navigator.of(context).pop();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không mở được trình duyệt: $uri')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.edit_note, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Đăng truyện',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Ứng dụng di động chỉ dành cho việc ĐỌC truyện '
              '(kể cả đọc offline và nghe bằng TTS không cần mạng). '
              'Để ĐĂNG truyện, bạn làm trên trình duyệt web theo 3 bước:',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            _Step(
              number: '1',
              text: 'Mở trang web khongdich.com và bấm “Đăng truyện” '
                  '(hay nút bên dưới để mở thẳng).',
            ),
            _Step(
              number: '2',
              text: 'Đăng nhập bằng tài khoản Google của bạn.',
            ),
            _Step(
              number: '3',
              text: 'Tạo truyện, thêm chương, chờ duyệt — mọi thao tác '
                  'quản lý truyện đều nằm trên web.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _open(context, ref),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Mở web đăng truyện'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Để sau'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});
  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
            child: Text(
              number,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the publish-guidance bottom sheet.
void showPublishWebSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const PublishWebSheet(),
  );
}