import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../reader/reader_settings_provider.dart';

/// Settings screen — plan §5.7. Includes theme mode + reader typography.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reader = ref.watch(readerSettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(
        children: [
          _SectionHeader('Hiển thị'),
          ListTile(
            leading: const Icon(Icons.text_fields),
            title: const Text('Cỡ chữ đọc truyện'),
            subtitle: Slider(
              min: 14,
              max: 28,
              divisions: 14,
              value: reader.fontSize,
              label: reader.fontSize.toStringAsFixed(0),
              onChanged: (v) =>
                  ref.read(readerSettingsProvider.notifier).setFontSize(v),
            ),
            trailing: Text(reader.fontSize.toStringAsFixed(0)),
          ),
          ListTile(
            leading: const Icon(Icons.height),
            title: const Text('Giãn dòng'),
            subtitle: Slider(
              min: 1.2,
              max: 2.2,
              divisions: 10,
              value: reader.lineHeight,
              label: reader.lineHeight.toStringAsFixed(1),
              onChanged: (v) =>
                  ref.read(readerSettingsProvider.notifier).setLineHeight(v),
            ),
            trailing: Text(reader.lineHeight.toStringAsFixed(1)),
          ),
          ListTile(
            leading: const Icon(Icons.font_download_outlined),
            title: const Text('Font chữ'),
            subtitle: Wrap(
              spacing: 6,
              children: [
                for (final fam in const ['NotoSerif', 'NotoSans', 'monospace'])
                  ChoiceChip(
                    label: Text(fam),
                    selected: reader.fontFamily == fam,
                    onSelected: (_) => ref
                        .read(readerSettingsProvider.notifier)
                        .setFontFamily(fam),
                  ),
              ],
            ),
          ),
          const Divider(),
          _SectionHeader('Tài khoản'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Đăng nhập với Google'),
            subtitle: const Text('Phase 2 — google_sign_in chưa wired'),
            onTap: () => _toast(context, 'Sẽ bật khi setup Firebase xong.'),
          ),
          const Divider(),
          _SectionHeader('Dữ liệu'),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('Xoá cache ảnh'),
            onTap: () => _toast(context, 'Chưa wired ở MVP scaffold.'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined,
                color: AppTheme.primary),
            title: const Text('Xoá toàn bộ truyện đã tải',
                style: TextStyle(color: AppTheme.primary)),
            onTap: () => _toast(context, 'Sẽ xoá khi Drift store online.'),
          ),
          const SizedBox(height: 32),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Không Dịch — MVP scaffold.\n'
              'Chi tiết roadmap: docs/plan-flutter-app.md (repo backend).',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AppTheme.primary,
            ),
      ),
    );
  }
}
