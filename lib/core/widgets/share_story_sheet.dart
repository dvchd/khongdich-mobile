import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../network/api_client.dart';

/// Share sheet for a story — mirrors the web story-detail's share
/// affordances (copy link + QR code) with native clipboard/snackbar UX.
///
/// The link uses the active environment's base URL (demo → demo domain),
/// so QA scans the right backend.
Future<void> showStoryShareSheet(
  BuildContext context, {
  required String storySlug,
  required String storyTitle,
}) async {
  final baseUrl = ProviderScope.containerOf(
    context,
  ).read(apiClientProvider).value?.baseUrl ?? 'https://khongdich.com';
  final url = '$baseUrl/truyen/$storySlug';

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Chia sẻ truyện',
              style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              storyTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(sheetContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(
                  sheetContext,
                ).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                url,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (!sheetContext.mounted) return;
                      Navigator.of(sheetContext).pop();
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          const SnackBar(
                            content: Text('Đã sao chép link'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                    },
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Sao chép link'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _showQrDialog(sheetContext, url),
                    icon: const Icon(Icons.qr_code_2, size: 18),
                    label: const Text('Mã QR'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// QR dialog — quiet-zone card like the web's QR modal, scannable on
/// screen. The app logo sits in the middle via [embeddedImageStyle].
///
/// Có nút "Chia sẻ ảnh QR" — render QR ra PNG (pixelRatio 3 → ~720px)
/// qua RepaintBoundary rồi mở share sheet (lưu vào Files/Drive/gửi...),
/// tương tự nút tải audio chương (TtsAudioExporter + share_plus).
void _showQrDialog(BuildContext sheetContext, String url) {
  showDialog<void>(
    context: sheetContext,
    builder: (_) => _QrShareDialog(url: url),
  );
}

class _QrShareDialog extends StatefulWidget {
  const _QrShareDialog({required this.url});
  final String url;

  @override
  State<_QrShareDialog> createState() => _QrShareDialogState();
}

class _QrShareDialogState extends State<_QrShareDialog> {
  final GlobalKey _qrKey = GlobalKey();
  bool _sharing = false;

  /// Render widget QR (bên trong [RepaintBoundary]) → PNG bytes.
  Future<Uint8List> _captureQrPng() async {
    final boundary =
        _qrKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // pixelRatio 3 → 240px * 3 = 720px — đủ nét cho ảnh chia sẻ/tải về.
    final image = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData!.buffer.asUint8List();
  }

  Future<void> _shareQr() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final png = await _captureQrPng();
      final dir = await getTemporaryDirectory();
      final slug = widget.url.split('/').last;
      final file = File('${dir.path}/qr-$slug.png')..writeAsBytesSync(png);
      if (!mounted) return;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          fileNameOverrides: ['qr-$slug.png'],
          subject: 'Chia sẻ truyện — Không Dịch',
        ),
      );
      if (result.status == ShareResultStatus.dismissed && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đã huỷ chia sẻ — ảnh QR vẫn lưu trong bộ nhớ tạm.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Chia sẻ ảnh QR thất bại: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Quét để mở truyện',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: RepaintBoundary(
                key: _qrKey,
                child: QrImageView(
                  data: widget.url,
                  version: QrVersions.auto,
                  size: 240,
                  padding: EdgeInsets.zero,
                  // EC level H (30%) — bắt buộc khi có logo chèn giữa (che
                  // ~22% module). qr_flutter mặc định L (7%) → máy quét
                  // không đọc được phần bị che. Web dùng H (`detail.html`).
                  errorCorrectionLevel: QrErrorCorrectLevel.H,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Color(0xFF0F172A),
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF0F172A),
                  ),
                  // Logo trên nền trắng bo tròn (giống web: vẽ hình tròn
                  // trắng trước, logo lên trên) — tăng nhận diện + máy quét
                  // phân biệt logo với module QR. Asset qr_logo.png đã
                  // vẽ sẵn nền tròn (mirror templates/story/detail.html).
                  embeddedImage:
                      const AssetImage('assets/icons/qr_logo.png'),
                  embeddedImageStyle: const QrEmbeddedImageStyle(
                    // ~21% cạnh QR (240px) — trong khoảng chuẩn ≤30%,
                    // logo bên trong nền tròn hiển thị ~50px.
                    size: Size(52, 52),
                  ),
                  semanticsLabel: widget.url,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Mở camera trên điện thoại khác và quét mã này.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Đóng'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _sharing ? null : _shareQr,
                  icon: _sharing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share, size: 18),
                  label: const Text('Chia sẻ ảnh QR'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
