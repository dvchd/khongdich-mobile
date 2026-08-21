import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../network/api_client.dart';
import '../../repositories/story_repository.dart';

/// Modal báo cáo vi phạm (story/chapter/comment/user) — tương tự modal
/// báo cáo trên web. Login-gated.
Future<void> showReportSheet(
  BuildContext context, {
  required String targetType,
  required String targetId,
  required String targetLabel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _ReportSheet(
        targetType: targetType,
        targetId: targetId,
        targetLabel: targetLabel,
      ),
    ),
  );
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({
    required this.targetType,
    required this.targetId,
    required this.targetLabel,
  });

  final String targetType;
  final String targetId;
  final String targetLabel;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  static const _reasons = [
    (Icons.campaign_outlined, 'spam', 'Spam'),
    (Icons.person_off_outlined, 'harassment', 'Quấy rối'),
    (Icons.sentiment_very_dissatisfied_outlined, 'hate_speech', 'Phát ngôn thù địch'),
    (Icons.local_police_outlined, 'violence', 'Bạo lực'),
    (Icons.visibility_off_outlined, 'sexual_content', 'Nội dung nhạy cảm'),
    (Icons.fact_check_outlined, 'misinformation', 'Thông tin sai lệch'),
    (Icons.copyright_outlined, 'copyright', 'Vi phạm bản quyền'),
    (Icons.more_horiz, 'other', 'Khác'),
  ];

  String? _reason;
  final TextEditingController _desc = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _desc.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _submitting) return;
    final api = ref.read(apiClientProvider).valueOrNull;
    if (api == null || !await api.isAuthenticated()) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đăng nhập để báo cáo.')),
        );
        context.push('/auth');
      }
      return;
    }
    setState(() => _submitting = true);
    try {
      await ref.read(storyRepositoryProvider).submitReport(
            targetType: widget.targetType,
            targetId: widget.targetId,
            reason: reason,
            description: _desc.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Đã gửi báo cáo. Cảm ơn bạn!'),
            duration: Duration(seconds: 2),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      final msg = e is ApiException ? e.message : '$e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gửi báo cáo thất bại: $msg')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Báo cáo ${widget.targetLabel}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Nội dung vi phạm sẽ được kiểm duyệt viên xử lý.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Lý do'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (icon, value, label) in _reasons)
                  ChoiceChip(
                    avatar: Icon(icon, size: 16),
                    label: Text(label),
                    selected: _reason == value,
                    onSelected: _submitting
                        ? null
                        : (sel) => setState(() => _reason = sel ? value : null),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _desc,
              minLines: 2,
              maxLines: 4,
              maxLength: 2000,
              decoration: InputDecoration(
                hintText: 'Mô tả chi tiết (tuỳ chọn)…',
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Huỷ'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _reason == null || _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.flag_outlined, size: 16),
                  label: const Text('Gửi báo cáo'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}