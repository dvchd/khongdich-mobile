import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../reader_settings_provider.dart';

/// Bottom-sheet UI for reader typography + theme. Plan §5.4.
class ReaderSettingsSheet extends ConsumerWidget {
  const ReaderSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(readerSettingsProvider);
    final notifier = ref.read(readerSettingsProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text(
                  'Tuỳ chọn đọc',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(),
            ListTile(
              dense: true,
              title: const Text('Cỡ chữ'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: s.fontSize <= 14
                        ? null
                        : () => notifier.setFontSize(s.fontSize - 1),
                  ),
                  Text('${s.fontSize.toStringAsFixed(0)}'),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: s.fontSize >= 28
                        ? null
                        : () => notifier.setFontSize(s.fontSize + 1),
                  ),
                ],
              ),
            ),
            ListTile(
              dense: true,
              title: const Text('Giãn dòng'),
              trailing: SizedBox(
                width: 180,
                child: Slider(
                  min: 1.2,
                  max: 2.4,
                  divisions: 12,
                  value: s.lineHeight,
                  label: s.lineHeight.toStringAsFixed(1),
                  onChanged: notifier.setLineHeight,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('Font chữ'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                children: [
                  for (final fam in const [
                    ('NotoSerif', 'Noto Serif'),
                    ('NotoSans', 'Noto Sans'),
                    ('monospace', 'Mono'),
                  ])
                    ChoiceChip(
                      label: Text(fam.$2),
                      selected: s.fontFamily == fam.$1,
                      onSelected: (_) => notifier.setFontFamily(fam.$1),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('Theme'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                children: [
                  for (final mode in ReaderThemeMode.values)
                    ChoiceChip(
                      label: Text(_modeLabel(mode)),
                      selected: s.theme == mode,
                      onSelected: (_) => notifier.setTheme(mode),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('Chế độ đọc'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                children: [
                  for (final mode in ReaderScrollMode.values)
                    ChoiceChip(
                      label: Text(_scrollLabel(mode)),
                      selected: s.scrollMode == mode,
                      onSelected: (_) => notifier.setScrollMode(mode),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  String _modeLabel(ReaderThemeMode mode) => switch (mode) {
        ReaderThemeMode.system => 'Theo hệ thống',
        ReaderThemeMode.light => 'Sáng',
        ReaderThemeMode.dark => 'Tối',
        ReaderThemeMode.sepia => 'Sepia',
      };

  String _scrollLabel(ReaderScrollMode mode) => switch (mode) {
        ReaderScrollMode.vertical => 'Cuộn dọc',
        ReaderScrollMode.horizontal => 'Lật trang',
      };
}
