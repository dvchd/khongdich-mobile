import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../downloads/offline_library_screen.dart'
    show downloadedChaptersCountProvider;
import '../publish_web_sheet.dart';

/// Home quick-launch card: offline read/listen highlight + shortcuts.
///
/// Replaces the old loud full-width gradient banner with a calm,
/// information-rich hero (Material tone, not "lộ liễu"): a real
/// offline-progress count from the local Drift store plus three
/// one-tap actions (Tủ truyện / Đã tải / Đăng truyện trên web).
class HomeHero extends ConsumerWidget {
  const HomeHero({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final downloaded = ref.watch(downloadedChaptersCountProvider).value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Hero card ─────────────────────────────────────────────
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                scheme.primaryContainer,
                scheme.surfaceContainerLow,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    downloaded != null && downloaded > 0
                        ? Icons.check_circle
                        : Icons.headphones,
                    size: 20,
                    color: scheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Đọc & nghe mọi lúc — kể cả khi không có mạng',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                downloaded != null && downloaded > 0
                    ? 'Bạn đã lưu $downloaded chương về máy. Tải truyện trước, sau đó đọc và nghe (TTS) hoàn toàn offline.'
                    : 'Tải truyện về máy để đọc và nghe (TTS) không cần internet — tiết kiệm data, đọc được cả khi mất mạng.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),

        // ── Quick actions ─────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              _QuickAction(
                icon: Icons.library_books_outlined,
                label: 'Tủ truyện',
                onTap: () => context.go('/bookshelf'),
              ),
              const SizedBox(width: 10),
              _QuickAction(
                icon: Icons.download_outlined,
                label: 'Đã tải',
                onTap: () => context.push('/offline-library'),
              ),
              const SizedBox(width: 10),
              _QuickAction(
                icon: Icons.edit_note,
                label: 'Đăng truyện',
                accent: true,
                onTap: () => showPublishWebSheet(context),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = accent ? AppTheme.primary : scheme.surfaceContainerHighest;
    final fg = accent ? Colors.white : scheme.onSurface;
    return Expanded(
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                Icon(icon, size: 22, color: fg),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}