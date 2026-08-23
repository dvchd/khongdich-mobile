import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/theme/app_theme.dart';
import '../../downloads/offline_library_screen.dart'
    show downloadedChaptersCountProvider;
import '../publish_web_sheet.dart';

/// Thẻ hero trên Home có bị user ẩn hẳng (nút X) hay không — persisted
/// qua SharedPreferences. Khi ẩn, thông tin đọc/nghe offline vẫn xem
/// được ở tab Cá nhân (tile "Đọc & nghe offline") và bật lại được trong
/// Cài đặt → Giao diện.
final homeHeroHiddenProvider = FutureProvider<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('home_hero_hidden') ?? false;
});

/// Home quick-launch card: offline read/listen highlight + shortcuts.
///
/// Replaces the old loud full-width gradient banner with a calm,
/// information-rich hero (Material tone, not "lộ liễu"): a real
/// offline-progress count from the local Drift store plus three
/// one-tap actions (Tủ truyện / Đã tải / Đăng truyện trên web).
///
/// Có nút X để ẩn vĩnh viễn (tiết kiệm diện tích cho ai không cần —
/// xem [homeHeroHiddenProvider]). Gradient dùng cùng family màu
/// primaryContainer (lerp về primary) thay vì pha surfaceContainerLow —
/// trong theme sáng surfaceContainerLow gần trắng, chữ
/// onPrimaryContainer bị mất tương phản nửa phải thẻ.
class HomeHero extends ConsumerWidget {
  const HomeHero({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final downloaded = ref.watch(downloadedChaptersCountProvider).value;

    // Đã ẩn bằng X → không render gì (thông tin chuyển về tab Cá nhân).
    if (ref.watch(homeHeroHiddenProvider).value ?? false) {
      return const SizedBox.shrink();
    }

    // Gradient 3 stop: primaryContainer → pha 45% primary → primary
    // (đậm dần chéo góc) + lớp gloss trắng mờ (foregroundDecoration)
    // + viền hairline trắng → hiệu ứng kính bóng bẩy nhưng vẫn giữ
    // tương phản chữ onPrimaryContainer.
    final heroMid = Color.lerp(scheme.primaryContainer, scheme.primary, 0.45)!;
    final heroBorder = Colors.white.withValues(alpha: 0.25);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Hero card ─────────────────────────────────────────────
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.primaryContainer,
                heroMid,
                scheme.primary,
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: heroBorder),
          ),
          // Lớp bóng (gloss sweep) chéo từ trên-trái mờ dần — vẽ TRÊN
          // nội dung nhưng alpha rất thấp nên không ảnh hưởng tương phản
          // chữ; decorations không chặn hit-testing của nút X.
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: const Alignment(0.4, 1.0),
              colors: [
                Colors.white.withValues(alpha: 0.16),
                Colors.white.withValues(alpha: 0.04),
                Colors.transparent,
              ],
              stops: const [0.0, 0.35, 0.65],
            ),
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
                  // X — ẩn hẳn thẻ (persist). Thông tin vẫn xem lại được
                  // ở Cá nhân; bật lại trong Cài đặt → Giao diện.
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      tooltip: 'Ẩn thẻ này (xem lại ở tab Cá nhân)',
                      icon: Icon(
                        Icons.close,
                        color: scheme.onPrimaryContainer
                            .withValues(alpha: 0.7),
                      ),
                      onPressed: () async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool('home_hero_hidden', true);
                        ref.invalidate(homeHeroHiddenProvider);
                      },
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
