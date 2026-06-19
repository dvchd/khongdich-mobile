import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';

/// Profile tab. Plan §5.7 — Settings entry + account section.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cá nhân')),
      body: ListView(
        children: [
          const _ProfileHeader(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: const Text('Tủ truyện'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/bookshelf'),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Lịch sử đọc'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _toast(context, 'Lịch sử đọc sẽ có ở Phase 2'),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Tải xuống'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/downloads'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Thông báo'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/notifications'),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Cài đặt'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: AppTheme.primary),
            title: const Text('Đăng xuất',
                style: TextStyle(color: AppTheme.primary)),
            onTap: () async {
              final api = ref.read(apiClientProvider).maybeWhen(
                    data: (c) => c,
                    orElse: () => null,
                  );
              if (api != null) {
                await api.clearAuth();
              }
              if (context.mounted) {
                _toast(context, 'Đã đăng xuất.');
                context.go('/home');
              }
            },
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Không Dịch v0.2.0 (MVP)\n'
              'Flutter 3.x · Riverpod · Drift · Dio · Custom markdown parser',
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
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}

class _ProfileHeader extends ConsumerWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: AppTheme.primary,
            child: const Icon(Icons.person, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Khách',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'Chưa đăng nhập',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: () => context.push('/auth'),
            child: const Text('Đăng nhập'),
          ),
        ],
      ),
    );
  }
}
