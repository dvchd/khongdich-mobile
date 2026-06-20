import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../reader/reader_settings_provider.dart';

/// Settings screen — plan §5.7. Includes:
///   - Reader typography (font, size, line height, theme)
///   - Backend environment switcher (demo / production)
///   - Account
///   - Cache management
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reader = ref.watch(readerSettingsProvider);
    final env = ref.watch(appEnvProvider);
    final appThemeMode = ref.watch(themeModeProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(
        children: [
          _Section('Giao diện'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Theme ứng dụng'),
            subtitle: Wrap(
              spacing: 6,
              children: [
                for (final mode in [
                  ('system', 'Theo hệ thống'),
                  ('light', 'Sáng'),
                  ('dark', 'Tối'),
                ])
                  ChoiceChip(
                    label: Text(mode.$2),
                    selected: appThemeMode.name == mode.$1,
                    onSelected: (_) {
                      ref.read(themeModeProvider.notifier).state =
                          ThemeMode.values.firstWhere(
                              (m) => m.name == mode.$1);
                    },
                  ),
              ],
            ),
          ),
          const Divider(),
          _Section('Môi trường'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Backend'),
            subtitle: Text(env.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showEnvSwitcher(context, ref),
          ),
          const Divider(),
          _Section('Hiển thị'),
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
                for (final fam in const [
                  ('NotoSerif', 'Noto Serif'),
                  ('NotoSans', 'Noto Sans'),
                  ('monospace', 'Mono'),
                ])
                  ChoiceChip(
                    label: Text(fam.$2),
                    selected: reader.fontFamily == fam.$1,
                    onSelected: (_) => ref
                        .read(readerSettingsProvider.notifier)
                        .setFontFamily(fam.$1),
                  ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Theme đọc truyện'),
            subtitle: Wrap(
              spacing: 6,
              children: [
                for (final mode in ReaderThemeMode.values)
                  ChoiceChip(
                    label: Text(_modeLabel(mode)),
                    selected: reader.theme == mode,
                    onSelected: (_) => ref
                        .read(readerSettingsProvider.notifier)
                        .setTheme(mode),
                  ),
              ],
            ),
          ),
          const Divider(),
          _Section('Tài khoản'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Đăng nhập với Google'),
            subtitle: const Text('Mở màn đăng nhập'),
            onTap: () => Navigator.of(context).pushNamed('auth'),
          ),
          const Divider(),
          _Section('Dữ liệu'),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('Xoá cache ảnh'),
            onTap: () => _toast(context, 'Cache ảnh sẽ được xoá khi đóng app.'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined,
                color: AppTheme.primary),
            title: const Text('Xoá toàn bộ truyện đã tải',
                style: TextStyle(color: AppTheme.primary)),
            onTap: () => _showClearDownloadsConfirm(context, ref),
          ),
          const Divider(),
          _Section('Về ứng dụng'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Không Dịch Mobile'),
            subtitle: Text('v0.3.0 — Bearer JWT + JSON API\n'
                'Tài liệu kế hoạch: docs/plan-flutter-app.md (repo backend)'),
          ),
        ],
      ),
    );
  }

  String _modeLabel(ReaderThemeMode mode) => switch (mode) {
        ReaderThemeMode.system => 'Theo hệ thống',
        ReaderThemeMode.light => 'Sáng',
        ReaderThemeMode.dark => 'Tối',
        ReaderThemeMode.sepia => 'Sepia',
      };

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showEnvSwitcher(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Chọn môi trường'),
        content: const Text(
          'Demo: demo.khongdich.com (test nội bộ)\n'
          'Production: khongdich.com (chính thức)\n\n'
          'Sau khi đổi, KHỞI ĐỘNG LẠI app để áp dụng.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Huỷ'),
          ),
          for (final e in AppEnv.values)
            FilledButton(
              onPressed: () async {
                final api = ref.read(apiClientProvider).maybeWhen(
                      data: (c) => c,
                      orElse: () => null,
                    );
                if (api != null) await api.setEnv(e);
                ref.read(appEnvProvider.notifier).state = e;
                if (context.mounted) {
                  Navigator.of(context).pop();
                  _toast(context, 'Đã đổi sang ${e.label}. Khởi động lại app.');
                }
              },
              child: Text(e.name.toUpperCase()),
            ),
        ],
      ),
    );
  }

  void _showClearDownloadsConfirm(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Xoá toàn bộ truyện đã tải?'),
        content: const Text(
            'Hành động này không thể hoàn tác. Tất cả chương đã tải sẽ bị xoá khỏi thiết bị.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              _toast(context, 'Đã xoá (sẽ wire hẳn với Drift ở bản tiếp).');
            },
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
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
