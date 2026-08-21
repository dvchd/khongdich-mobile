import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../network/api_client.dart';
import '../../repositories/story_repository.dart';

/// Nút Theo dõi tác giả (dùng chung: màn hình tác giả + story detail).
/// Login-gated: chưa đăng nhập → bấm mở màn đăng nhập.
class FollowButton extends ConsumerStatefulWidget {
  const FollowButton({
    super.key,
    required this.authorId,
    this.initialFollowing = false,
    this.initialFollowerCount = 0,
    this.compact = false,
  });

  final String authorId;
  final bool initialFollowing;
  final int initialFollowerCount;

  /// Compact = chỉ icon+chữ ngắn, không kèm số người theo dõi.
  final bool compact;

  @override
  ConsumerState<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends ConsumerState<FollowButton> {
  late bool _following = widget.initialFollowing;
  late int _followerCount = widget.initialFollowerCount;
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    final api = ref.read(apiClientProvider).valueOrNull;
    if (api == null || !await api.isAuthenticated()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đăng nhập để theo dõi tác giả.')),
        );
        context.push('/auth');
      }
      return;
    }
    setState(() => _busy = true);
    try {
      final (following, count) = await ref
          .read(storyRepositoryProvider)
          .toggleFollow(widget.authorId);
      if (!mounted) return;
      setState(() {
        _following = following;
        _followerCount = count;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              following ? 'Đã theo dõi tác giả.' : 'Đã bỏ theo dõi tác giả.',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Thao tác thất bại: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final following = _following;
    final text = _busy
        ? 'Đang xử lý…'
        : (following ? 'Đang theo dõi' : 'Theo dõi');

    Widget button;
    if (widget.compact) {
      button = TextButton.icon(
        onPressed: _busy ? null : _toggle,
        icon: const Icon(Icons.person_add_alt, size: 16),
        label: Text(text),
      );
    } else if (following) {
      button = OutlinedButton.icon(
        onPressed: _busy ? null : _toggle,
        icon: const Icon(Icons.check, size: 16),
        label: Text('$text · $_followerCount'),
      );
    } else {
      button = FilledButton.icon(
        onPressed: _busy ? null : _toggle,
        style: FilledButton.styleFrom(
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
        ),
        icon: const Icon(Icons.person_add_alt, size: 16),
        label: Text('$text · $_followerCount'),
      );
    }

    if (widget.compact) return button;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: button,
    );
  }
}