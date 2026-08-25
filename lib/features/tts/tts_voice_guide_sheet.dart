import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/observability/app_logger.dart';
import 'tts_audio_handler.dart';
import 'tts_settings_launcher.dart';

/// Tên engine hiển thị cho user từ package name của engine TTS.
///
/// Package name trả về bởi `flutter_tts.getEngines()` không thân thiện
/// (`com.google.android.tts`, `com.samsung.SMT`, ...) — map sang tên
/// đọc được để hiển thị trong hướng dẫn.
String ttsEngineDisplayName(String? engine) {
  if (engine == null || engine.isEmpty) return 'Engine mặc định của máy';
  final e = engine.toLowerCase();
  if (e.contains('google')) {
    return 'Google (Speech Recognition & Synthesis)';
  }
  if (e.contains('samsung') || e.contains('smt')) return 'Samsung TTS';
  if (e.contains('huawei')) return 'Huawei TTS';
  return engine;
}

/// Bottom sheet hướng dẫn cập nhật giọng đọc.
///
/// Giọng đọc KHÔNG nằm trong app — nó đến từ engine TTS của máy
/// (Google/Samsung/Huawei). Giọng cũ hoặc thiếu dữ liệu tiếng Việt
/// thường do engine chưa được cập nhật hoặc chưa tải voice data.
/// Sheet này mở CH Play (cập nhật engine Google), cài đặt TTS hệ thống
/// (chọn engine + tải dữ liệu giọng) và Galaxy Store (giọng Samsung
/// chất lượng cao), rồi nạp lại danh sách giọng trong app.
class VoiceUpdateGuideSheet extends StatefulWidget {
  const VoiceUpdateGuideSheet({super.key, required this.handler});

  final TtsAudioHandler handler;

  @override
  State<VoiceUpdateGuideSheet> createState() => _VoiceUpdateGuideSheetState();
}

class _VoiceUpdateGuideSheetState extends State<VoiceUpdateGuideSheet> {
  bool _refreshing = false;

  static const _googlePlayAppId = 'com.google.android.tts';
  static const _samsungTtsAppId = 'com.samsung.SMT';

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openGooglePlay() async {
    // market:// mở thẳng trang app trong CH Play; https:// là fallback
    // cho máy không có app CH Play (hiếm — app này cài qua CH Play).
    for (final uri in [
      Uri.parse('market://details?id=$_googlePlayAppId'),
      Uri.parse('https://play.google.com/store/apps/details?id=$_googlePlayAppId'),
    ]) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return;
        }
      } catch (e, s) {
        AppLogger.warning('Voice guide: mở CH Play thất bại', e, s);
      }
    }
    _toast('Không mở được CH Play. Tìm "Speech Recognition and Synthesis '
        'from Google" trên CH Play và bấm Cập nhật.');
  }

  Future<void> _openGalaxyStore() async {
    final uri = Uri.parse(
        'https://apps.samsung.com/appquery/appDetail.as?appId=$_samsungTtsAppId');
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (e, s) {
      AppLogger.warning('Voice guide: mở Galaxy Store thất bại', e, s);
    }
    _toast('Không mở được Galaxy Store. Mở Galaxy Store trên máy Samsung '
        'và tìm "Samsung TTS".');
  }

  Future<void> _openTtsSettings() async {
    final ok = await TtsSettingsLauncher.openSystemTtsSettings();
    if (!ok) {
      _toast('Máy này không cho mở cài đặt TTS trực tiếp. Vào Cài đặt → '
          'Ngôn ngữ & nhập liệu → Text-to-speech (hoặc Trợ năng → '
          'Text-to-speech output).');
    }
  }

  Future<void> _refreshVoices() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.handler.reinit();
      if (mounted) {
        _toast('Đã nạp lại. Giọng mới xuất hiện trong mục Giọng đọc — '
            'bấm Phát nếu muốn nghe giọng mới ngay.');
      }
    } catch (e, s) {
      AppLogger.warning('Voice guide: reinit thất bại', e, s);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final engineName = ttsEngineDisplayName(widget.handler.selectedEngine);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.record_voice_over,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Cập nhật giọng đọc',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Giọng đọc đến từ engine TTS cài trên máy, không phải từ app. '
              'Giọng nghe "cũ" hoặc thiếu dữ liệu tiếng Việt thường do '
              'engine chưa được cập nhật hoặc chưa tải voice data. Làm '
              'theo các bước dưới đây:',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.record_voice_over, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Engine hiện tại: $engineName',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _step(
              context,
              1,
              'Cập nhật engine Google mới nhất (CH Play). Giọng tiếng Việt '
              'neural của Google được cải thiện qua từng bản cập nhật app.',
            ),
            _step(
              context,
              2,
              'Mở cài đặt TTS của máy → chọn đúng engine → "Cài đặt dữ liệu '
              'giọng nói" → kiểm tra tiếng Việt đã được cài. Nếu đang dùng '
              'giọng ngoại tuyến, bấm tải lại để có bản mới.',
            ),
            _step(
              context,
              3,
              'Máy Samsung: Galaxy Store → Samsung TTS → tải giọng tiếng '
              'Việt chất lượng cao (dung lượng lớn, nên dùng Wi-Fi) rồi '
              'chọn Samsung TTS làm engine.',
            ),
            _step(
              context,
              4,
              'Quay lại app và bấm "Nạp lại danh sách giọng" để thấy giọng '
              'mới trong mục Giọng đọc.',
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _openGooglePlay,
              icon: const Icon(Icons.update),
              label: const Text('Mở CH Play — cập nhật giọng Google'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _openTtsSettings,
              icon: const Icon(Icons.settings),
              label: const Text('Mở cài đặt TTS của máy'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _openGalaxyStore,
              icon: const Icon(Icons.storefront),
              label: const Text('Galaxy Store — Samsung TTS'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _refreshing ? null : _refreshVoices,
              icon: _refreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(_refreshing ? 'Đang nạp lại...' : 'Nạp lại danh sách giọng'),
            ),
            const SizedBox(height: 8),
            Text(
              'Lưu ý: cập nhật engine/giọng chỉ áp dụng cho âm thanh phát '
              'SAU đó. Nếu đang nghe, bấm Phát lại để nghe giọng mới.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _step(BuildContext context, int index, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: theme.colorScheme.primary,
            child: Text(
              '$index',
              style: TextStyle(
                color: theme.colorScheme.onPrimary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
